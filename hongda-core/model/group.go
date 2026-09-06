package model

import "context"

type GroupHealth struct {
	Ready     bool
	LastError string
}

// Group is a strategy group (select / urltest / fallback / balance) built on
// top of Outbound. It never reaches into protocol internals.
type Group interface {
	Outbound
	Members() []string
	Current() string
	Health() GroupHealth
	Refresh(ctx context.Context) error
}
