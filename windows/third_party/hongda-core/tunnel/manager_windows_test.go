//go:build windows && with_gvisor

package tunnel

import (
	"errors"
	"testing"
)

func TestStaleTUNAddressError(t *testing.T) {
	if !staleTUNAddressError(errors.New("set ipv6 address: The object already exists.")) {
		t.Fatal("Windows stale address error was not recognized")
	}
	if staleTUNAddressError(errors.New("access is denied")) {
		t.Fatal("unrelated Wintun error was classified as stale address")
	}
}
