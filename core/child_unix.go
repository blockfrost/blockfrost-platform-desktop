// +build !windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"time"
)

func setManagedChildSysProcAttr(cmd *exec.Cmd) {
}

// setOpenFileLimit wraps cmd in a shell that sets RLIMIT_NOFILE before
// exec-ing the real binary.  If n <= 0 the command is left unchanged.
//
// Go's runtime manages RLIMIT_NOFILE internally and restores the original
// (low) soft limit for child processes, so syscall.Setrlimit in the parent
// alone is not sufficient.
//
// Three extra argv entries ("/bin/sh", "-c", "ulimit … exec …") are
// prepended, with the original path landing in $0 so that
// 'exec "$0" "$@"' re-execs the real binary without any shell-level quoting.
func setOpenFileLimit(cmd *exec.Cmd, n int) {
	if n <= 0 {
		return
	}
	origPath := cmd.Path
	cmd.Path = "/bin/sh"
	newArgv := make([]string, 0, 4+len(cmd.Args))
	newArgv = append(newArgv, "sh", "-c", fmt.Sprintf(`ulimit -n %d; exec "$0" "$@"`, n), origPath)
	newArgv = append(newArgv, cmd.Args[1:]...)
	cmd.Args = newArgv
}

func windowsSendCtrlBreak(pid int) {
	panic("windowsSendCtrlBreak is only supported on Windows")
}

func inheritExtraFiles(cmd *exec.Cmd, extraFiles []*os.File) {
	cmd.ExtraFiles = extraFiles
}

func childProcessPTYWindows(
	path string, argv []string, extraEnv []string,
	logModifier func(string) string, // e.g. to drop redundant timestamps
	outputLines chan<- string, terminate <-chan struct{}, pid *int,
	terminateGracefullyByInheritedFd3 bool,
	gracefulExitTimeout time.Duration,
	openFileLimit int,
) {
	panic("childProcessPTYWindows is only supported on Windows")
}
