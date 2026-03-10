//go:build !windows
// +build !windows

package main

import (
	"errors"
	"time"
)

func probeWindowsNamedPipe(path string, timeout time.Duration) error {
	return errors.New("probeWindowsNamedPipe is only supported on Windows")
}
