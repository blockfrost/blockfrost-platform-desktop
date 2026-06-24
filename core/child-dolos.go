package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"

	"blockfrost.io/blockfrost-platform-desktop/constants"
	"blockfrost.io/blockfrost-platform-desktop/ourpaths"

	"github.com/acarl005/stripansi"
)

type DolosPreRunState struct {
	DolosWorkDir             string
	ChainDir                 string
	MarkerPath               string
	IsFreshBootstrap         bool
	HasChainDir              bool
	BootstrappingFromMithril bool
}

func dolosPreRunState(shared SharedState) DolosPreRunState {
	sep := string(filepath.Separator)

	dolosWorkDir := ourpaths.WorkDir + sep + shared.Network + sep + "dolos"
	chainDir := ourpaths.WorkDir + sep + shared.Network + sep + "chain"

	// A marker file that exists only while a Mithril-based Dolos bootstrap is in
	// progress. We create it before starting `dolos bootstrap mithril`, and only
	// remove it once that finishes cleanly (exit 0). So if it’s still here on a
	// later launch, the previous bootstrap was interrupted (app quit / crash) and
	// we should resume it (`--continue`) rather than fall back to a very slow
	// daemon-mode catch-up from a real `cardano-node`.
	markerPath := ourpaths.DolosBootstrapMarkerPath(shared.Network)

	// No Dolos data dir yet → this is a fresh bootstrap, not a resume of an
	// interrupted one (which would have left partial data behind).
	_, err := os.Stat(dolosWorkDir)
	isFreshBootstrap := err != nil

	_, err = os.Stat(chainDir)
	hasChainDir := err == nil

	_, err = os.Stat(markerPath)
	mithrilBootstrapPreviouslyInterrupted := err == nil

	// Bootstrap from the local `cardano-node` chain directory (probably a
	// Mithril snapshot) when there’s no Dolos data yet, or when a prior such
	// bootstrap was interrupted and must be resumed.
	bootstrappingFromMithril := hasChainDir && (isFreshBootstrap || mithrilBootstrapPreviouslyInterrupted)

	return DolosPreRunState{
		DolosWorkDir:             dolosWorkDir,
		ChainDir:                 chainDir,
		MarkerPath:               markerPath,
		IsFreshBootstrap:         isFreshBootstrap,
		HasChainDir:              hasChainDir,
		BootstrappingFromMithril: bootstrappingFromMithril,
	}
}

func childDolos() func(SharedState, chan<- StatusAndUrl) ManagedChild {
	return func(shared SharedState, statusCh chan<- StatusAndUrl) ManagedChild {
		sep := string(filepath.Separator)

		serviceName := "dolos"
		exePath := ourpaths.LibexecDir + sep + "dolos" + sep + "dolos" + ourpaths.ExeSuffix
		tempConfigPath := ""

		removeTimestamp := func(line string, when time.Time) string {
			needle := when.Format("2006-01-02T15:04:05.")
			index := strings.Index(line, needle)
			if index != -1 {
				end := index + len(needle) + 7
				if end > len(line) {
					end = len(line)
				}
				return line[:index] + line[end:]
			}
			return line
		}

		// Now, if `cardano-node`’s chain directory already exists (either the node
		// synced before, or the user used Mithril), we can bootstrap Dolos from
		// these files securely (it takes long).
		//
		// Otherwise, we need to start both Dolos, and Cardano node in parallel, so
		// that the normal sync of both takes the least amount of time.
		//
		// If the user gives up, and chooses Mithril, then `child-mithril.go` will
		// remove the Dolos work directory, so on the next restart it will be
		// recreated based on that fresh Mithril snapshot.

		prs := dolosPreRunState(shared)

		// A mini-monster, we’ll be able to get rid of it once Dolos provides more machine-readable output:
		reProgress := regexp.MustCompile(
			`^\[[0-9:]+\]\s+[#>-]+\s+([0-9]*)/([0-9]*)\s*([^(]+)\(eta:\s+([0-9]*)([A-Za-z]+)\)\s*(.*)$`)
		reTimestamp := regexp.MustCompile(
			`^\[[0-9:]+\]\s+`)

		unitToSeconds := func(unit string) int64 {
			switch unit {
			case "s":
				return 1
			case "m":
				return 60
			case "h":
				return 60 * 60
			case "d":
				return 60 * 60 * 24
			default:
				return -1 // signal that something’s off
			}
		}

		// For log debouncing:
		restoreProgressLastEmitted := time.Now()

		// We use it in `PostStop` to see if a Mithril bootstrap got interrupted:
		bootstrapExitCode := -1

		return ManagedChild{
			ServiceName: serviceName,
			ExePath:     exePath,
			Version:     constants.DolosVersion,
			Revision:    constants.DolosRevision,
			ExitCode:    &bootstrapExitCode,
			MkArgv: func() ([]string, error) {
				*shared.DolosPort = getFreeTCPPort()
				templatePath := ourpaths.ResourcesDir + sep + "dolos-config" + sep + shared.Network + sep + "dolos.toml"
				tmp, err := generateDolosConfig(templatePath, map[string]string{
					"PEER_ADDRESS":         fmt.Sprintf("127.0.0.1:%d", *shared.CardanoNodePort),
					"DOLOS_STORAGE_PATH":   prs.DolosWorkDir,
					"DOLOS_MINIBF_PORT":    fmt.Sprintf("%d", *shared.DolosPort),
					"GENESIS_PATH_BYRON":   shared.CardanoNodeConfigDir + sep + "byron-genesis.json",
					"GENESIS_PATH_SHELLEY": shared.CardanoNodeConfigDir + sep + "shelley-genesis.json",
					"GENESIS_PATH_ALONZO":  shared.CardanoNodeConfigDir + sep + "alonzo-genesis.json",
					"GENESIS_PATH_CONWAY":  shared.CardanoNodeConfigDir + sep + "conway-genesis.json",
				})
				if err != nil {
					fmt.Printf("%s[%d]: config generation failed: %v\n", serviceName, -1, err)
					return nil, err
				}
				tempConfigPath = tmp

				if prs.BootstrappingFromMithril || prs.IsFreshBootstrap {
					statusCh <- StatusAndUrl{
						Status:      "bootstrapping",
						Progress:    -1,
						TaskSize:    -1,
						SecondsLeft: -1,
						Url:         "",
						OmitUrl:     false,
					}
				}

				if prs.BootstrappingFromMithril {
					// Record that a Mithril-based bootstrap is underway. If we get
					// interrupted (app quit / crash) before it finishes cleanly, this
					// marker survives and makes the next launch resume it (see below)
					// instead of falling back to a very slow daemon-mode catch-up.
					if err := os.WriteFile(prs.MarkerPath,
						[]byte("a `dolos bootstrap mithril` is in progress; "+
							"if this file is still here, it was interrupted\n"),
						0o644); err != nil {
						fmt.Printf("%s[%d]: warning: could not write bootstrap marker %q: %v\n",
							serviceName, -1, prs.MarkerPath, err)
					}

					argv := []string{
						"--config", tempConfigPath,
						"bootstrap", "mithril",
						"--download-dir", prs.ChainDir,
						"--skip-download",
						"--retain-snapshot",
						"--skip-validation",
					}

					// If Dolos data already exists, a previous bootstrap was interrupted,
					// so resume it with `--continue` (without it, Dolos refuses to run on
					// existing data). NB: resuming from a non-recoverable interruption
					// point can still fail (a Dolos bug being fixed upstream,
					// txpipe/dolos#1016); the user’s fallback is to re-trigger a full
					// Mithril resync, which wipes this data and clears the marker.
					if !prs.IsFreshBootstrap {
						fmt.Printf("%s[%d]: resuming an interrupted Mithril bootstrap with `--continue`\n",
							serviceName, -1)
						argv = append(argv, "--continue")
					}

					return argv, nil
					// After this long bootstrapping ends, everything will be restarted in `daemon` mode.
				}

				// Otherwise, just run the daemon which continues to sync via
				// chain-sync off the local `cardano-node`).
				return []string{
					"--config", tempConfigPath,
					"daemon",
				}, nil
			},
			MkExtraEnv:  func() []string { return []string{} },
			PostStart:   func() error { return nil },
			AllocatePTY: prs.BootstrappingFromMithril, // Mithril restore progress is available only on TTY
			StatusCh:    statusCh,
			HealthProbe: func(prev HealthStatus) HealthStatus {
				dolosUrl := fmt.Sprintf("http://127.0.0.1:%d", *shared.DolosPort)
				body, err := probeHttpWithBodyFor([]int{200}, dolosUrl+"/blocks/latest", 3*time.Second, true)
				nextProbeIn := 1 * time.Second

				if err == nil {
					type Payload struct {
						Time uint64 `json:"time"` // [s] UNIX timestamp of the latest block
					}

					var payload Payload
					err = json.Unmarshal([]byte(body), &payload)
					if err == nil {
						current := payload.Time          // [s]
						now := uint64(time.Now().Unix()) // [s]

						progress := float64(current-shared.NetworkStartTime) / float64(now-shared.NetworkStartTime)
						status := "syncing"
						if progress >= 0.99995 {
							progress = 1.0
							status = "listening"
						}

						statusCh <- StatusAndUrl{
							Status:      status,
							Progress:    progress,
							TaskSize:    -1,
							SecondsLeft: -1,
							Url:         dolosUrl,
							OmitUrl:     false,
						}
						nextProbeIn = 60 * time.Second
					}
				}
				return HealthStatus{
					Initialized: err == nil,
					DoRestart:   false,
					NextProbeIn: nextProbeIn,
					LastErr:     err,
				}
			},
			LogMonitor: func(line string) {
				if prs.BootstrappingFromMithril {
					if ms := reProgress.FindStringSubmatch(line); len(ms) > 0 {
						numDone, _ := strconv.ParseInt(ms[1], 10, 64)
						done := float64(numDone)
						numTotal, _ := strconv.ParseInt(ms[2], 10, 64)
						total := float64(numTotal)
						if total == 0.0 {
							total = 1.0
						}
						progress := done / total
						// unitDone := ms[3]
						// unitTotal := unitDone

						numTimeRemaining, _ := strconv.ParseInt(ms[4], 10, 64)
						unitTimeRemaining := ms[5]
						timeRemaining := float64(numTimeRemaining) * float64(unitToSeconds(unitTimeRemaining))

						description := ms[6]

						statusCh <- StatusAndUrl{
							Status: description, Progress: progress,
							TaskSize: total, SecondsLeft: timeRemaining, OmitUrl: true,
						}
						return // there would be no way to have `else if` here, hence early return
					} else if !strings.Contains(line, " ERROR ") &&
						!strings.HasPrefix(line, "d proposal proposal=") {
						// FIXME: unignore errors after Dolos 1.0.0
						description := reTimestamp.ReplaceAllString(line, "")
						statusCh <- StatusAndUrl{
							Status: description, Progress: -1,
							TaskSize: -1, SecondsLeft: -1, OmitUrl: true,
						}
					}
				}
			},
			LogModifier: func(line string) string {
				if !prs.BootstrappingFromMithril {
					now := time.Now().UTC()
					line = removeTimestamp(line, now)
					line = removeTimestamp(line, now.Add(-1*time.Second))
					if runtime.GOOS == "windows" {
						// garbled output on cmd.exe instead:
						line = stripansi.Strip(line)
					}
					return line
				} else {
					// Remove the wigglers (⠙, ⠒, etc.):
					brailleDotsLow := rune(0x2800)
					brailleDotsHi := rune(0x28ff)
					var result strings.Builder
					for _, char := range line {
						if char < brailleDotsLow || char > brailleDotsHi {
							result.WriteRune(char)
						}
					}
					line = result.String()
					line = strings.TrimSpace(line)

					// Debounce the restore progress bar, it’s way too frequent:
					if ms := reProgress.FindStringSubmatch(line); len(ms) > 0 {
						if time.Since(restoreProgressLastEmitted) >= 333*time.Millisecond {
							restoreProgressLastEmitted = time.Now()
						} else {
							line = ""
						}
					}

					return line
				}
			},
			OpenFileLimit:                     4096,
			TerminateGracefullyByInheritedFd3: false,
			ForceKillAfter:                    5 * time.Second,
			PostStop: func() error {
				if tempConfigPath != "" {
					_ = os.Remove(tempConfigPath)
				}
				// A Mithril bootstrap that exited cleanly (0) is complete, so drop the
				// marker and let the next launch go straight to daemon mode. Any other
				// exit (non-zero, or killed → -1) means we were interrupted, so we keep
				// the marker and resume with `--continue` on the next launch.
				if prs.BootstrappingFromMithril && bootstrapExitCode == 0 {
					if err := os.Remove(prs.MarkerPath); err != nil && !os.IsNotExist(err) {
						fmt.Printf("%s[%d]: warning: could not remove bootstrap marker %q: %v\n",
							serviceName, -1, prs.MarkerPath, err)
					} else {
						fmt.Printf("%s[%d]: Mithril bootstrap finished cleanly; cleared the resume marker\n",
							serviceName, -1)
					}
				}
				return nil
			},
		}
	}
}

func renderTemplate(contents string, subs map[string]string) string {
	re := regexp.MustCompile(`\$\{([A-Za-z0-9_]+)\}`)
	return re.ReplaceAllStringFunc(contents, func(m string) string {
		key := m[2 : len(m)-1] // strip ${ and }
		if v, ok := subs[key]; ok {
			return strings.ReplaceAll(v, `\`, `\\`) // for Windows paths
		}
		return m
	})
}

func generateDolosConfig(templatePath string, subs map[string]string) (string, error) {
	b, err := os.ReadFile(templatePath)
	if err != nil {
		return "", err
	}
	rendered := renderTemplate(string(b), subs)
	tmp, err := os.CreateTemp("", "dolos-*.toml")
	if err != nil {
		return "", err
	}
	tempPath := tmp.Name()
	if _, err := tmp.WriteString(rendered); err != nil {
		_ = tmp.Close()
		return "", err
	}
	if err := tmp.Close(); err != nil { // important for Windows
		return "", err
	}
	return tempPath, nil
}
