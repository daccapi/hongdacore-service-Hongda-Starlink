// Hongda Core is an independent, clean-room proxy core. It does not import
// sing-box or mihomo code; it only implements the same argv and HTTP surface
// so the existing HongdaService/Flutter UI can drive it.
package main

import (
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"hongda.local/hongda-core/config"
	"hongda.local/hongda-core/core"
)

const (
	version        = "1.2.0"
	featureSummary = "direct,vless,trojan,reality,utls,ws,grpc,rules,doh,mixed,socks5,http,clash-api,ipc"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch strings.ToLower(strings.TrimSpace(os.Args[1])) {
	case "version", "--version", "-v":
		fmt.Printf("HongdaCore %s\n", version)
	case "features":
		fmt.Println(featureSummary)
	case "check":
		if err := runCheck(argConfig(os.Args[2:])); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		fmt.Println("HONGDA_CHECK_OK")
	case "run":
		if err := runProxy(argConfig(os.Args[2:])); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	default:
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "HongdaCore - independent proxy core")
	fmt.Fprintln(os.Stderr, "usage: hongda-core version|features|check|run")
}

func argConfig(args []string) string {
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "-c", "--config":
			if i+1 < len(args) {
				return args[i+1]
			}
		default:
			if strings.HasPrefix(args[i], "--config=") {
				return strings.TrimPrefix(args[i], "--config=")
			}
		}
	}
	return "config.json"
}

func runCheck(path string) error {
	_, err := config.Load(path)
	return err
}

func runProxy(path string) error {
	cfg, err := config.Load(path)
	if err != nil {
		return err
	}
	runtime := core.NewRuntime(cfg)
	if err := runtime.Build(); err != nil {
		return err
	}
	if err := runtime.Start(); err != nil {
		return err
	}
	fmt.Printf("HongdaCore %s ready\n", version)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	<-sig
	_ = runtime.Close()
	fmt.Println("HONGDA_STOPPED")
	return nil
}
