package main

import (
	"fmt"
	"path/filepath"
	"time"

	"iog.io/blockchain-services/constants"
	"iog.io/blockchain-services/ourpaths"
)

func childBlockfrostPlatform(shared SharedState, statusCh chan<- StatusAndUrl) ManagedChild {
	sep := string(filepath.Separator)

	return ManagedChild{
		ServiceName: "blockfrost-platform",
		ExePath: ourpaths.LibexecDir + sep + "blockfrost-platform" + sep + "blockfrost-platform" + ourpaths.ExeSuffix,
		Version: constants.BlockfrostPlatformVersion,
		Revision: constants.BlockfrostPlatformRevision,
		MkArgv: func() ([]string, error) {
			*shared.BlockfrostPlatformPort = getFreeTCPPort()
			return []string{
				"--solitary",
				"--server-address", "127.0.0.1",
				"--server-port", fmt.Sprintf("%d", *shared.BlockfrostPlatformPort),
				"--network", shared.Network,
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
			err := probeHttpFor([]int{ 200, 202 }, blockfrostPlatformUrl + "/", 1 * time.Second)
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
				nextProbeIn = 60 * time.Second
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
		PostStop: func() error { return nil },
	}
}
