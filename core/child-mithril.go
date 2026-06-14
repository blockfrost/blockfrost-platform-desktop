package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"blockfrost.io/blockfrost-platform-desktop/appconfig"
	"blockfrost.io/blockfrost-platform-desktop/constants"
	"blockfrost.io/blockfrost-platform-desktop/ourpaths"
)

// mithrilJSONEvent is one line of `mithril-client --json` output. Depending on
// which fields are present, it’s either a step transition, a download-progress
// update (labelled "Files" for immutables, or "Ancillary" for the ledger state),
// or the final success result (which carries a non-empty `db_directory`).
type mithrilJSONEvent struct {
	StepNum         *int     `json:"step_num"`
	Message         string   `json:"message"`
	Label           string   `json:"label"`
	FilesDownloaded *float64 `json:"files_downloaded"`
	FilesTotal      *float64 `json:"files_total"`
	BytesDownloaded *float64 `json:"bytes_downloaded"`
	BytesTotal      *float64 `json:"bytes_total"`
	SecondsLeft     *float64 `json:"seconds_left"`
	DbDirectory     string   `json:"db_directory"`
}

func childMithril(appConfig appconfig.AppConfig) func(SharedState, chan<- StatusAndUrl) ManagedChild {
	return func(shared SharedState, statusCh chan<- StatusAndUrl) ManagedChild {
		sep := string(filepath.Separator)

		upstream := map[string]string{
			"preview": constants.MithrilAggregatorPreview,
			"preprod": constants.MithrilAggregatorPreprod,
			"mainnet": constants.MithrilAggregatorMainnet,
		}

		// Capture the real upstream aggregator for this network before any
		// forced-snapshot proxy overwrites it below; we query it for the
		// snapshot’s byte sizes (best-effort) to drive a GiB progress bar.
		realAggregator := upstream[shared.Network]

		if appConfig.ForceMithrilSnapshot.Preview.Digest != "" {
			upstream["preview"] = fmt.Sprintf("http://127.0.0.1:%d/preview", shared.MithrilCachePort)
		}
		if appConfig.ForceMithrilSnapshot.Preprod.Digest != "" {
			upstream["preprod"] = fmt.Sprintf("http://127.0.0.1:%d/preprod", shared.MithrilCachePort)
		}
		if appConfig.ForceMithrilSnapshot.Mainnet.Digest != "" {
			upstream["mainnet"] = fmt.Sprintf("http://127.0.0.1:%d/mainnet", shared.MithrilCachePort)
		}

		extraEnv := map[string][]string{
			"preview": {
				"NETWORK=preview",
				"AGGREGATOR_ENDPOINT=" + upstream["preview"],
				"GENESIS_VERIFICATION_KEY=" + constants.MithrilGVKPreview,
				"ANCILLARY_VERIFICATION_KEY=" + constants.MithrilAVKPreview,
			},
			"preprod": {
				"NETWORK=preprod",
				"AGGREGATOR_ENDPOINT=" + upstream["preprod"],
				"GENESIS_VERIFICATION_KEY=" + constants.MithrilGVKPreprod,
				"ANCILLARY_VERIFICATION_KEY=" + constants.MithrilAVKPreprod,
			},
			"mainnet": {
				"NETWORK=mainnet",
				"AGGREGATOR_ENDPOINT=" + upstream["mainnet"],
				"GENESIS_VERIFICATION_KEY=" + constants.MithrilGVKMainnet,
				"ANCILLARY_VERIFICATION_KEY=" + constants.MithrilAVKMainnet,
			},
		}

		serviceName := "mithril-client"
		exePath := ourpaths.LibexecDir + sep + "mithril-client" + sep + "mithril-client" + ourpaths.ExeSuffix
		snapshotsDir := ourpaths.WorkDir + sep + "mithril-snapshots"
		downloadDir := "" // set later
		unpackDir := ""   // set later

		const SInitializing = "initializing"
		const SCheckingDisk = "checking local disk info"
		const SCertificates = "fetching & verifying cert info"
		const SDownloadingUnpacking = "downloading & unpacking"
		const SDownloadingDigests = "downloading & verifying digests"
		const SVerifyingDB = "verifying DB"
		const SDigest = "computing digest"
		const SVerifyingSignature = "verifying signature"
		const SGoodSignature = "good signature"
		const SMovingDB = "moving DB"
		const SFinished = "finished"

		currentStatus := SInitializing

		// For log debouncing:
		downloadProgressLastEmitted := time.Now()

		// Snapshot byte sizes (uncompressed) fetched best-effort from the
		// aggregator in MkArgv, plus the live per-stream download accumulators.
		// When `dbTotalBytes > 0` we merge the parallel immutables ("Files") and
		// ancillary ("Ancillary") streams into a single GiB progress bar;
		// otherwise we fall back to file-count progress.
		var dbTotalBytes, immBytes, ancBytes float64
		var immDownloaded, ancDownloaded float64
		var immSecondsLeft, ancSecondsLeft float64

		explorerUrl := ""
		for _, envVar := range extraEnv[shared.Network] {
			varName := "AGGREGATOR_ENDPOINT="
			if strings.HasPrefix(envVar, varName) {
				// Note: this should somehow point to the snapshot, but they don’t support that yet?
				explorerUrl = "https://mithril.network/explorer?" +
					url.QueryEscape(strings.Replace(envVar, varName, "aggregator=", 1))
				break
			}
		}

		// Dereferences an optional float from Mithril’s JSON, with a fallback:
		derefF := func(p *float64, dflt float64) float64 {
			if p == nil {
				return dflt
			}
			return *p
		}

		// Emits a combined GiB download-progress update, merging the parallel
		// immutables + ancillary streams against the total uncompressed DB size.
		// The ETA is the larger of the two remaining times (step 3 finishes when
		// the slower stream does); -1 means “unknown”.
		emitMithrilDownload := func() {
			secondsLeft := immSecondsLeft
			if ancSecondsLeft > secondsLeft {
				secondsLeft = ancSecondsLeft
			}
			statusCh <- StatusAndUrl{
				Status: currentStatus, Progress: (immDownloaded + ancDownloaded) / dbTotalBytes,
				TaskSize: dbTotalBytes, SecondsLeft: secondsLeft, OmitUrl: true,
			}
		}

		return ManagedChild{
			ServiceName: serviceName,
			ExePath:     exePath,
			Version:     constants.MithrilClientVersion,
			Revision:    constants.MithrilClientRevision,
			MkArgv: func() ([]string, error) {
				snapshot := "latest"
				snapshotOverrides := map[string]string{
					"preview": appConfig.ForceMithrilSnapshot.Preview.Digest,
					"preprod": appConfig.ForceMithrilSnapshot.Preprod.Digest,
					"mainnet": appConfig.ForceMithrilSnapshot.Mainnet.Digest,
				}
				if snapshotOverrides[shared.Network] != "" {
					snapshot = snapshotOverrides[shared.Network]
				}

				// Reset per-session download accumulators, then best-effort fetch the
				// snapshot’s uncompressed byte sizes so we can show a GiB progress bar.
				// Only `latest` is served by the real aggregator; forced snapshots go
				// through a local proxy that doesn’t expose these sizes, so we just
				// fall back to file-count progress there.
				dbTotalBytes, immBytes, ancBytes = 0, 0, 0
				immDownloaded, ancDownloaded = 0, 0
				immSecondsLeft, ancSecondsLeft = -1, -1
				if snapshot == "latest" {
					if total, ancillary, ok := fetchCardanoDbSizes(realAggregator); ok {
						dbTotalBytes = total
						ancBytes = ancillary
						immBytes = total - ancillary
						if immBytes < 0 {
							immBytes = 0
						}
					}
				}

				downloadDir = snapshotsDir + sep + shared.Network + sep + snapshot
				err := os.MkdirAll(downloadDir, 0o755)
				if err != nil {
					return nil, err
				}

				unpackDir = downloadDir + sep + "db"

				// XXX: it’s possible that the unpack directory already exists from a previous run;
				// XXX: then Mithril errors out, so let’s delete it:
				if _, err := os.Stat(unpackDir); !os.IsNotExist(err) {
					if err := os.RemoveAll(unpackDir); err != nil {
						return nil, err
					}
				}

				fmt.Printf("%s[%d]: will download snapshot %v to %v\n",
					serviceName, os.Getpid(), snapshot, downloadDir)

				return []string{
					"--json", // machine-readable progress & step events (on stderr)
					"cardano-db",
					"download",
					snapshot,
					"--include-ancillary",
					"--download-dir",
					downloadDir,
				}, nil
			},
			MkExtraEnv: func() []string {
				return extraEnv[shared.Network]
			},
			PostStart: func() error { return nil },
			// With `--json`, Mithril streams machine-readable progress to stderr
			// even when not attached to a TTY, so we no longer need a PTY here:
			AllocatePTY: false,
			StatusCh:    statusCh,
			HealthProbe: func(prev HealthStatus) HealthStatus {
				return HealthStatus{
					Initialized: true,
					DoRestart:   false,
					NextProbeIn: 10 * time.Second,
					LastErr:     nil,
				}
			},
			LogMonitor: func(line string) {
				// With `--json`, Mithril emits one JSON object per line. Step &
				// progress events go to stderr (hence the `[stderr] ` prefix our
				// pipe reader adds), the final success result goes to stdout.
				line = strings.TrimPrefix(line, "[stderr] ")
				if !strings.HasPrefix(line, "{") {
					return
				}
				var ev mithrilJSONEvent
				if json.Unmarshal([]byte(line), &ev) != nil {
					return
				}

				// The final result, printed only on success, carries `db_directory`:
				if ev.DbDirectory != "" {
					currentStatus = SGoodSignature
					statusCh <- StatusAndUrl{
						Status: currentStatus, Progress: -1,
						TaskSize: -1, SecondsLeft: -1, OmitUrl: true,
					}
					return
				}

				// Step transitions (1..7), in the order Mithril runs them:
				if ev.StepNum != nil {
					switch *ev.StepNum {
					case 1:
						currentStatus = SCheckingDisk
					case 2:
						currentStatus = SCertificates
					case 3:
						currentStatus = SDownloadingUnpacking
					case 4:
						currentStatus = SDownloadingDigests
					case 5:
						currentStatus = SVerifyingDB
					case 6:
						currentStatus = SDigest
					case 7:
						currentStatus = SVerifyingSignature
					default:
						return
					}
					statusCh <- StatusAndUrl{
						Status: currentStatus, Progress: -1,
						TaskSize: -1, SecondsLeft: -1,
						// only attach the explorer URL on the very first step:
						Url: explorerUrl, OmitUrl: *ev.StepNum != 1,
					}
					return
				}

				// Download progress: immutables are reported by file count (Mithril
				// gives no byte totals there), the ancillary (ledger state) by bytes:
				switch ev.Label {
				case "Files":
					total := derefF(ev.FilesTotal, 1)
					if total == 0 {
						total = 1
					}
					frac := derefF(ev.FilesDownloaded, 0) / total
					if dbTotalBytes > 0 {
						// Combined GiB bar: map the immutables file-fraction onto
						// their share of the uncompressed DB size.
						immDownloaded = frac * immBytes
						immSecondsLeft = derefF(ev.SecondsLeft, -1)
						emitMithrilDownload()
					} else {
						// Fallback: aggregator sizes unavailable, report by file count.
						statusCh <- StatusAndUrl{
							Status: currentStatus, Progress: frac,
							TaskSize: -1, SecondsLeft: derefF(ev.SecondsLeft, -1), OmitUrl: true,
						}
					}
				case "Ancillary":
					total := derefF(ev.BytesTotal, 1)
					if total == 0 {
						total = 1
					}
					frac := derefF(ev.BytesDownloaded, 0) / total
					if dbTotalBytes > 0 {
						// Combined GiB bar: the reported bytes are compressed, so use
						// the fraction against the uncompressed ancillary size.
						ancDownloaded = frac * ancBytes
						ancSecondsLeft = derefF(ev.SecondsLeft, -1)
						emitMithrilDownload()
					} else {
						// Fallback: report the ancillary’s own (compressed) byte total.
						statusCh <- StatusAndUrl{
							Status: currentStatus, Progress: frac,
							TaskSize: total, SecondsLeft: derefF(ev.SecondsLeft, -1), OmitUrl: true,
						}
					}
				}
			},
			LogModifier: func(line string) string {
				// Download-progress events arrive several times per second; debounce
				// them so we don’t spam the log or (on Windows) the tray UI. They’re
				// the only events carrying a `seconds_elapsed` field:
				if strings.Contains(line, "seconds_elapsed") {
					if time.Since(downloadProgressLastEmitted) >= 333*time.Millisecond {
						downloadProgressLastEmitted = time.Now()
					} else {
						return ""
					}
				}

				return line
			},
			TerminateGracefullyByInheritedFd3: false,
			ForceKillAfter:                    5 * time.Second,
			PostStop: func() error {
				if currentStatus != SGoodSignature {
					// Since Mithril cannot resume interrupted downloads, let’s clear them on failures:
					os.RemoveAll(downloadDir)

					return fmt.Errorf("cannot move DB as snapshot download was not successful")
				}
				currentStatus = SMovingDB
				statusCh <- StatusAndUrl{
					Status: currentStatus, Progress: -1,
					TaskSize: -1, SecondsLeft: -1, OmitUrl: true,
				}

				chainDir := ourpaths.WorkDir + sep + shared.Network + sep + "chain"
				chainDirBackup := chainDir + "--bak--" + time.Now().UTC().Format("2006-01-02--15-04-05Z")

				err := os.Rename(chainDir, chainDirBackup)
				if err != nil {
					return err
				}

				err = os.Rename(unpackDir, chainDir)
				if err != nil {
					return err
				}

				err = os.RemoveAll(downloadDir)
				if err != nil {
					return err
				}

				err = os.RemoveAll(chainDirBackup)
				if err != nil {
					return err
				}

				// Clear Dolos data dir (if it exists), it will be recreated based on the Mithril snapshot
				dolosWorkDir := ourpaths.WorkDir + sep + shared.Network + sep + "dolos"
				if _, err := os.Stat(dolosWorkDir); err == nil {
					err = os.RemoveAll(dolosWorkDir)
					if err != nil {
						return err
					}
				}

				currentStatus = SFinished
				statusCh <- StatusAndUrl{
					Status: currentStatus, Progress: -1,
					TaskSize: -1, SecondsLeft: -1, OmitUrl: true,
				}

				return nil
			},
		}
	}
}

// cardanoDbSnapshotListItem and cardanoDbSnapshotDetail model the subset of the
// Mithril aggregator’s `/artifact/cardano-database[/{hash}]` responses we need.
type cardanoDbSnapshotListItem struct {
	Hash   string `json:"hash"`
	Beacon struct {
		ImmutableFileNumber int `json:"immutable_file_number"`
	} `json:"beacon"`
}

type cardanoDbSnapshotDetail struct {
	TotalDbSizeUncompressed float64 `json:"total_db_size_uncompressed"`
	Ancillary               struct {
		SizeUncompressed float64 `json:"size_uncompressed"`
	} `json:"ancillary"`
}

// fetchCardanoDbSizes queries the aggregator for the latest Cardano DB snapshot
// and returns its total and ancillary *uncompressed* sizes, in bytes. It’s
// best-effort: any error returns ok=false, and callers then fall back to
// file-count progress. "Latest" is chosen by the highest immutable file number,
// which is robust against the list’s ordering.
func fetchCardanoDbSizes(aggregatorEndpoint string) (total float64, ancillary float64, ok bool) {
	if aggregatorEndpoint == "" {
		return 0, 0, false
	}

	client := &http.Client{Timeout: 10 * time.Second}

	listURL := strings.TrimRight(aggregatorEndpoint, "/") + "/artifact/cardano-database"
	resp, err := client.Get(listURL)
	if err != nil {
		return 0, 0, false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 0, 0, false
	}

	var list []cardanoDbSnapshotListItem
	if json.NewDecoder(resp.Body).Decode(&list) != nil || len(list) == 0 {
		return 0, 0, false
	}

	latest := list[0]
	for _, item := range list[1:] {
		if item.Beacon.ImmutableFileNumber > latest.Beacon.ImmutableFileNumber {
			latest = item
		}
	}
	if latest.Hash == "" {
		return 0, 0, false
	}

	detailURL := listURL + "/" + latest.Hash
	resp2, err := client.Get(detailURL)
	if err != nil {
		return 0, 0, false
	}
	defer resp2.Body.Close()
	if resp2.StatusCode != http.StatusOK {
		return 0, 0, false
	}

	var detail cardanoDbSnapshotDetail
	if json.NewDecoder(resp2.Body).Decode(&detail) != nil {
		return 0, 0, false
	}
	if detail.TotalDbSizeUncompressed <= 0 {
		return 0, 0, false
	}

	return detail.TotalDbSizeUncompressed, detail.Ancillary.SizeUncompressed, true
}

func runCommandWithTimeout(
	command string,
	args []string,
	extraEnv []string,
	timeout time.Duration,
	stdin *string, // use nil to not set
) ([]byte, []byte, int, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, command, args...)

	setManagedChildSysProcAttr(cmd)

	// Against possible orphaned child processes during timeout, but so far Mithril doesn’t have them:
	cmd.WaitDelay = 1 * time.Second

	if len(extraEnv) > 0 {
		cmd.Env = append(os.Environ(), extraEnv...)
	}

	var stdoutBuf, stderrBuf bytes.Buffer
	cmd.Stdout = &stdoutBuf
	cmd.Stderr = &stderrBuf

	if stdin != nil {
		cmd.Stdin = strings.NewReader(*stdin)
	}

	err := cmd.Run()
	var rerr error

	if ctx.Err() == context.DeadlineExceeded {
		rerr = fmt.Errorf("timed out")
	} else if err != nil {
		rerr = fmt.Errorf("failed: %s", err)
	}

	pid := -1
	if cmd.Process != nil {
		pid = cmd.Process.Pid
	}

	return stdoutBuf.Bytes(), stderrBuf.Bytes(), pid, rerr
}
