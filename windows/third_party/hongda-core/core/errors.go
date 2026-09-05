package core

import "errors"

var (
	ErrNotBuilt   = errors.New("runtime has not been built")
	ErrNotRunning = errors.New("runtime is not running")
)
