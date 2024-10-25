package main

import (
	"fmt"
	"os"
	"sync"
	"bufio"
	"runtime"
	"time"

	"github.com/acarl005/stripansi"
)

func duplicateOutputToFile(logFile string) func() {
	originalStdout := os.Stdout
	originalStderr := os.Stderr

	newLine := "\n"
	if (runtime.GOOS == "windows") {
		newLine = "\r\n"
	}

	fp, err := os.Create(logFile)
	if err != nil {
	    panic(err)
	}

	introLine := "-- Log begins at " + time.Now().UTC().Format("Mon 2006-01-02 15:04:05") + " UTC. --"
	fmt.Println(introLine)
	fp.WriteString(introLine + newLine)

	newStdoutR, newStdoutW, err := os.Pipe()
	if err != nil {
	    panic(err)
	}
	os.Stdout = newStdoutW

	newStderrR, newStderrW, err := os.Pipe()
	if err != nil {
	    panic(err)
	}
	os.Stderr = newStderrW

	logTime := func() string {
		return time.Now().UTC().Format("Jan 2 15:04:05.000Z")
	}

	var wgScanners sync.WaitGroup
	wgScanners.Add(2)

	type LogLine struct {
		timestamp string
		isStderr bool
		msg string
	}

	lines := make(chan LogLine)

	go func() {
		scanner := bufio.NewScanner(newStdoutR)
		for scanner.Scan() {
			lines <- LogLine { timestamp: logTime(), isStderr: false, msg: scanner.Text() }
		}
		wgScanners.Done()
	}()

	go func() {
		scanner := bufio.NewScanner(newStderrR)
		for scanner.Scan() {
			lines <- LogLine { timestamp: logTime(), isStderr: true, msg: scanner.Text() }
		}
		wgScanners.Done()
	}()

	writerDone := make(chan struct{})

	go func() {
		defer fp.Close()
		for line := range lines {
			stderrPrefix := ""
			if line.isStderr {
				stderrPrefix = "[stderr] "
				originalStderr.WriteString(line.timestamp + " " + line.msg + newLine)
			} else {
				originalStdout.WriteString(line.timestamp + " " + line.msg + newLine)
			}
			fp.WriteString(line.timestamp + " " + stderrPrefix + stripansi.Strip(line.msg) + newLine)
		}
		writerDone <- struct{}{}
	}()

	// Wait, making sure that everything is indeed written before exiting:
	closeOutputs := func(){
		newStdoutW.Close()
		newStderrW.Close()
		os.Stdout = originalStdout
		os.Stderr = originalStderr
		wgScanners.Wait()
		close(lines)
		<-writerDone

		bufio.NewWriter(os.Stdout).Flush()
		bufio.NewWriter(os.Stderr).Flush()
		os.Stdout.Sync()
		os.Stderr.Sync()

		// XXX: for whatever reason this is needed after integrating WebKit;
		// otherwise the terminal eats the last line. When you pipe through `|
		// cat`, it works again. Flushing/syncing/closing changes nothing. Note
		// that this line is _sometimes_ written to the terminal, but rarely,
		// like 1 in 10 times? Some race condition in stdlib? :/
		fmt.Fprintln(os.Stdout)
	}

	return closeOutputs
}
