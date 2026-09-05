//go:build windows

package route

import (
	"fmt"
	"unsafe"

	"golang.org/x/sys/windows"
)

var dnsCacheEntropy = []byte("HongdaStarlink.DNSCache.v1")

func protectDNSCache(data []byte) ([]byte, error) {
	return transformDNSCacheDPAPI(data, true)
}

func unprotectDNSCache(data []byte) ([]byte, error) {
	return transformDNSCacheDPAPI(data, false)
}

func transformDNSCacheDPAPI(data []byte, protect bool) ([]byte, error) {
	if len(data) == 0 {
		return nil, fmt.Errorf("empty DNS cache payload")
	}
	input := windows.DataBlob{Size: uint32(len(data)), Data: &data[0]}
	entropy := windows.DataBlob{Size: uint32(len(dnsCacheEntropy)), Data: &dnsCacheEntropy[0]}
	var output windows.DataBlob
	var err error
	if protect {
		err = windows.CryptProtectData(
			&input, nil, &entropy, 0, nil,
			windows.CRYPTPROTECT_UI_FORBIDDEN, &output,
		)
	} else {
		err = windows.CryptUnprotectData(
			&input, nil, &entropy, 0, nil,
			windows.CRYPTPROTECT_UI_FORBIDDEN, &output,
		)
	}
	if err != nil {
		return nil, err
	}
	defer windows.LocalFree(windows.Handle(uintptr(unsafe.Pointer(output.Data))))
	outputBytes := unsafe.Slice(output.Data, int(output.Size))
	transformed := append([]byte(nil), outputBytes...)
	clear(outputBytes)
	return transformed, nil
}
