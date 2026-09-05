package protocol

import (
	"fmt"

	"hongda.local/hongda-core/model"
)

// NewOutbound constructs a concrete outbound from a unified Node. Protocol
// adapters register here without exposing their internal objects.
func NewOutbound(node model.Node) (model.Outbound, error) {
	switch node.Type {
	case model.ProtocolDirect:
		return NewDirect(node.ID), nil
	case model.ProtocolVLESS:
		return NewVLESS(node)
	case model.ProtocolTrojan:
		return NewTrojan(node)
	default:
		return nil, fmt.Errorf("protocol %q not implemented yet", node.Type)
	}
}
