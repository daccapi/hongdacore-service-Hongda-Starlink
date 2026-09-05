//go:build !windows

package main

import (
	"io"
)

type nopCloser struct{}

func (nopCloser) Close() error { return nil }

func attachKillOnCloseJob(pid int) (io.Closer, error) {
	return nopCloser{}, nil
}
