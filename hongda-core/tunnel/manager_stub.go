//go:build !windows || !with_gvisor

package tunnel

import (
	"fmt"

	"hongda.local/hongda-core/model"
	"hongda.local/hongda-core/route"
)

type unavailable struct{}

func Supported() bool { return false }

func New(_ model.InboundConfig, _ *route.Router, _ *model.Config) (Manager, error) {
	return nil, fmt.Errorf("TUN requires a Windows build with the with_gvisor tag")
}

func (*unavailable) Start() error { return nil }
func (*unavailable) Close() error { return nil }
