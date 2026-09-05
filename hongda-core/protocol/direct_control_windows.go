//go:build windows

package protocol

import (
	"syscall"

	"github.com/sagernet/sing/common/control"
)

func interfaceControl(index int) func(string, string, syscall.RawConn) error {
	if index <= 0 {
		return nil
	}
	return control.BindToInterface(nil, "", index)
}
