//go:build !windows

package protocol

import "syscall"

func interfaceControl(int) func(string, string, syscall.RawConn) error { return nil }
