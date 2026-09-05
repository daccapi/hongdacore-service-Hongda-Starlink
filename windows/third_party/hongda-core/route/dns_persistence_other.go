//go:build !windows

package route

func protectDNSCache(data []byte) ([]byte, error) {
	return append([]byte(nil), data...), nil
}

func unprotectDNSCache(data []byte) ([]byte, error) {
	return append([]byte(nil), data...), nil
}
