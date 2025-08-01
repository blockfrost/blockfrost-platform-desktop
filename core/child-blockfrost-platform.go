package main

import (
	"fmt"
	"path/filepath"
	"time"
	"strconv"
	"regexp"
	"os"

	"blockfrost.io/blockfrost-platform-desktop/constants"
	"blockfrost.io/blockfrost-platform-desktop/ourpaths"
)

func childBlockfrostPlatform(syncProgressCh chan<- float64) func(SharedState, chan<- StatusAndUrl) ManagedChild { return func(shared SharedState, statusCh chan<- StatusAndUrl) ManagedChild {
	sep := string(filepath.Separator)

	serviceName := "blockfrost-platform"
	tempConfigPath := ""
	reSyncProgress := regexp.MustCompile(`"sync_progress"\s*:\s*(\d*\.\d+)`)

	return ManagedChild{
		ServiceName: serviceName,
		ExePath: ourpaths.LibexecDir + sep + "blockfrost-platform" + sep + "blockfrost-platform" + ourpaths.ExeSuffix,
		Version: constants.BlockfrostPlatformVersion,
		Revision: constants.BlockfrostPlatformRevision,
		MkArgv: func() ([]string, error) {
			*shared.BlockfrostPlatformPort = getFreeTCPPort()

			// FIXME: currently we can’t pass Dolos via --dolos-endpoint,
			// there's a bug in the Blockfrost platform,
			// <https://github.com/blockfrost/blockfrost-platform/issues/353>
			tmp, err := generateBFPConfig(shared)
			if err != nil {
				fmt.Printf("%s[%d]: config generation failed: %v\n", serviceName, -1, err)
				return nil, err
			}
			tempConfigPath = tmp;

			return []string{
				"--config", tempConfigPath,
				"--solitary",
				"--server-address", "127.0.0.1",
				"--server-port", fmt.Sprintf("%d", *shared.BlockfrostPlatformPort),
				"--log-level", "info",
				"--node-socket-path", shared.CardanoNodeSocket,
				"--mode", "compact",
			}, nil
		},
		MkExtraEnv: func() []string { return []string{} },
		PostStart: func() error { return nil },
		AllocatePTY: false,
		StatusCh: statusCh,
		HealthProbe: func(prev HealthStatus) HealthStatus {
			blockfrostPlatformUrl := fmt.Sprintf("http://127.0.0.1:%d", *shared.BlockfrostPlatformPort)
			body, err := probeHttpWithBodyFor([]int{ 200 }, blockfrostPlatformUrl + "/", 1 * time.Second, true)
			nextProbeIn := 1 * time.Second
			if (err == nil) {
				statusCh <- StatusAndUrl {
					Status: "listening",
					Progress: -1,
					TaskSize: -1,
					SecondsLeft: -1,
					Url: blockfrostPlatformUrl,
					OmitUrl: false,
				}

				if ms := reSyncProgress.FindStringSubmatch(body); len(ms) > 0 {
					num, err := strconv.ParseFloat(ms[1], 64)
					if err == nil {
						syncProgressCh <- num / 100.0
					}
				}

				nextProbeIn = 10 * time.Second
			}
			return HealthStatus {
				Initialized: err == nil,
				DoRestart: false,
				NextProbeIn: nextProbeIn,
				LastErr: err,
			}
		},
		LogMonitor: func(line string) {},
		LogModifier: func(line string) string { return line },
		TerminateGracefullyByInheritedFd3: false,
		ForceKillAfter: 5 * time.Second,
		PostStop: func() error {
			if tempConfigPath != "" {
				_ = os.Remove(tempConfigPath)
			}
			return nil
		},
	}
}}

func generateBFPConfig(shared SharedState) (string, error) {
	rendered :=	fmt.Sprintf(`
[data_sources.dolos]
endpoint = "%s"
request_timeout = %d
`, fmt.Sprintf("http://127.0.0.1:%d", *shared.DolosPort), 30)
	tmp, err := os.CreateTemp("", "blockfrost-platform-*.toml")
	if err != nil { return "", err }
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
