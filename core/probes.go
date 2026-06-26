package main

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"time"
)

func getFreeTCPPort() int {
	sock, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		panic(err)
	}
	defer sock.Close()

	// Retrieve the address of the listener
	address := sock.Addr().(*net.TCPAddr)
	return address.Port
}

func probeUnixSocket(path string, timeout time.Duration) error {
	conn, err := net.DialTimeout("unix", path, timeout)
	if err == nil {
		defer conn.Close()
	}
	return err
}

func probeHttpWithBodyFor(acceptedStatusCodes []int, url string, timeout time.Duration, withBody bool) (string, error) {
	httpClient := http.Client{Timeout: timeout}

	resp, err := httpClient.Get(url)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	body := ""
	if withBody {
		bodyBytes, err := io.ReadAll(resp.Body)
		if err != nil {
			return "", fmt.Errorf("failed to read response body: %v", err)
		}
		body = string(bodyBytes)
	}

	for _, code := range acceptedStatusCodes {
		if resp.StatusCode == code {
			return body, nil
		}
	}

	return body, fmt.Errorf(
		"got an unexpected response code: %d for %s, expected one of %v",
		resp.StatusCode, url, acceptedStatusCodes,
	)
}
