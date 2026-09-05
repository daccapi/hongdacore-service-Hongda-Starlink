// SPDX-License-Identifier: GPL-3.0-or-later
//
// HongdaService is the Windows-side supervisor for Hongda Starlink.
// It embeds the locally built independent HongdaCore Windows runtime and
// extracts it into the user's local application data directory on demand.
package main

import (
	"bufio"
	"context"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	serviceVersion = "1.5.8"
	coreVersion    = "1.10.8"
)

const featureSummary = "direct,vless,trojan,hysteria2,tuic,reality,utls,ws,grpc,vless-vision,vless-xudp,rules,remote-rule-set,rule-set-cache,rule-set-fallback,rule-set-offline-start,rule-set-prefix-trie,doh,doh-keepalive,dns-hijack,tcp-dns-hijack,dns-rule-reject,dns-route-cache,dns-query-cache,tls-sni-sniff,udp-associate,udp-proxy,mixed,socks5,http-connect,tun,wintun,gvisor,strict-route,tun-restart-recovery,interface-bind,clash-api,loopback-api,connection-log,connection-log-delta,connection-stream"

//go:embed embedded/HongdaCore.exe
var coreBinary []byte

type errorFrame struct {
	Phase    string `json:"phase"`
	Message  string `json:"message"`
	ExitCode int    `json:"exitCode,omitempty"`
	Detail   string `json:"detail,omitempty"`
}

type ipcRequest struct {
	ID     string                 `json:"id"`
	Method string                 `json:"method"`
	Params map[string]interface{} `json:"params,omitempty"`
}

type ipcResponse struct {
	ID     string      `json:"id,omitempty"`
	OK     bool        `json:"ok"`
	Result interface{} `json:"result,omitempty"`
	Error  string      `json:"error,omitempty"`
}

type runtimeFiles struct {
	Dir       string
	Core      string
	CoreSHA   string
	CoreBytes int
}

func main() {
	if runtime.GOOS != "windows" {
		// Cross-builds are supported; running this executable is Windows-only.
	}
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}

	command := strings.ToLower(strings.TrimSpace(os.Args[1]))
	var err error
	switch command {
	case "version", "--version", "-v":
		err = printVersion()
	case "features":
		fmt.Println(featureSummary)
	case "doctor":
		err = doctor(configPath(os.Args[2:]))
	case "check":
		err = checkConfig(configPath(os.Args[2:]))
	case "run":
		err = runService(configPath(os.Args[2:]))
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		var reported *reportedError
		if !errors.As(err, &reported) {
			emitError(errorFrame{Phase: "service", Message: err.Error()})
		}
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "HongdaService - bundled HongdaCore supervisor")
	fmt.Fprintln(os.Stderr, "usage:")
	fmt.Fprintln(os.Stderr, "  HongdaService.exe version")
	fmt.Fprintln(os.Stderr, "  HongdaService.exe features")
	fmt.Fprintln(os.Stderr, "  HongdaService.exe doctor -c <config.json>")
	fmt.Fprintln(os.Stderr, "  HongdaService.exe check  -c <config.json>")
	fmt.Fprintln(os.Stderr, "  HongdaService.exe run    -c <config.json>")
}

func configPath(args []string) string {
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

func emitError(frame errorFrame) {
	payload, _ := json.Marshal(frame)
	fmt.Fprintf(os.Stderr, "HONGDA_ERROR %s\n", payload)
}

type reportedError struct {
	err error
}

func (e *reportedError) Error() string {
	if e == nil || e.err == nil {
		return "HongdaService error"
	}
	return e.err.Error()
}

func (e *reportedError) Unwrap() error {
	if e == nil {
		return nil
	}
	return e.err
}

func reportError(frame errorFrame, err error) error {
	emitError(frame)
	if err == nil {
		err = errors.New(frame.Message)
	}
	return &reportedError{err: err}
}

func serviceDataDir() (string, error) {
	if root := strings.TrimSpace(os.Getenv("LOCALAPPDATA")); root != "" {
		return filepath.Join(root, "HongdaStarlink", "runtime", coreVersion), nil
	}
	cache, err := os.UserCacheDir()
	if err != nil {
		return "", fmt.Errorf("resolve user cache directory: %w", err)
	}
	return filepath.Join(cache, "HongdaStarlink", "runtime", coreVersion), nil
}

func sha256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func ensureRuntime() (runtimeFiles, error) {
	if len(coreBinary) < 5*1024*1024 {
		return runtimeFiles{}, errors.New("embedded HongdaCore is missing or truncated")
	}
	dir, err := serviceDataDir()
	if err != nil {
		return runtimeFiles{}, err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return runtimeFiles{}, fmt.Errorf("create runtime directory %s: %w", dir, err)
	}

	corePath := filepath.Join(dir, "HongdaCore.exe")
	coreSHA := sha256Hex(coreBinary)
	if err := writeEmbeddedIfNeeded(corePath, coreBinary, coreSHA, 0o755); err != nil {
		return runtimeFiles{}, fmt.Errorf("extract HongdaCore: %w", err)
	}
	return runtimeFiles{
		Dir:       dir,
		Core:      corePath,
		CoreSHA:   coreSHA,
		CoreBytes: len(coreBinary),
	}, nil
}

func writeEmbeddedIfNeeded(path string, data []byte, expectedSHA string, mode os.FileMode) error {
	if existing, err := os.ReadFile(path); err == nil && sha256Hex(existing) == expectedSHA {
		return nil
	}
	tmp := path + ".tmp"
	_ = os.Remove(tmp)
	if err := os.WriteFile(tmp, data, mode); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(path)
		if retryErr := os.Rename(tmp, path); retryErr != nil {
			_ = os.Remove(tmp)
			return retryErr
		}
	}
	return nil
}

func printVersion() error {
	files, err := ensureRuntime()
	if err != nil {
		return err
	}
	out, err := exec.Command(files.Core, "version").CombinedOutput()
	if err != nil {
		return fmt.Errorf("query HongdaCore version: %w: %s", err, compact(string(out)))
	}
	versionOutput := compact(string(out))
	if !strings.Contains(versionOutput, coreVersion) {
		return fmt.Errorf("HongdaCore version mismatch: expected %s, got %s", coreVersion, versionOutput)
	}
	fmt.Printf("HongdaService %s · HongdaCore %s · embedded core sha256:%s\n", serviceVersion, coreVersion, files.CoreSHA[:12])
	return nil
}

func doctor(config string) error {
	files, err := ensureRuntime()
	if err != nil {
		return reportError(errorFrame{Phase: "core_extract", Message: err.Error()}, err)
	}
	absolute, err := filepath.Abs(config)
	if err != nil {
		return reportError(errorFrame{Phase: "config_path", Message: err.Error()}, err)
	}
	if info, statErr := os.Stat(absolute); statErr != nil || info.IsDir() {
		msg := fmt.Sprintf("config file not found: %s", absolute)
		if statErr != nil {
			msg = statErr.Error()
		}
		return reportError(errorFrame{Phase: "config_missing", Message: msg}, errors.New(msg))
	}
	if err := runCheck(files, absolute); err != nil {
		return err
	}
	result := map[string]interface{}{
		"ok":             true,
		"serviceVersion": serviceVersion,
		"coreVersion":    coreVersion,
		"corePath":       files.Core,
		"coreSha256":     files.CoreSHA,
		"coreBytes":      files.CoreBytes,
		"config":         absolute,
		"features":       strings.Split(featureSummary, ","),
	}
	payload, _ := json.Marshal(result)
	fmt.Printf("HONGDA_DOCTOR %s\n", payload)
	return nil
}

func checkConfig(config string) error {
	files, err := ensureRuntime()
	if err != nil {
		return reportError(errorFrame{Phase: "core_extract", Message: err.Error()}, err)
	}
	absolute, err := filepath.Abs(config)
	if err != nil {
		return reportError(errorFrame{Phase: "config_path", Message: err.Error()}, err)
	}
	return runCheck(files, absolute)
}

func runCheck(files runtimeFiles, absolute string) error {
	if _, err := os.Stat(absolute); err != nil {
		wrapped := fmt.Errorf("config file unavailable %s: %w", absolute, err)
		return reportError(errorFrame{Phase: "config_missing", Message: wrapped.Error()}, wrapped)
	}
	cmd := exec.Command(files.Core, "check", "-c", absolute)
	cmd.Dir = files.Dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		code := exitCode(err)
		detail := compact(string(out))
		frame := errorFrame{Phase: "config_check", Message: "HongdaCore configuration check failed", ExitCode: code, Detail: detail}
		return reportError(frame, fmt.Errorf("%s: %s", frame.Message, detail))
	}
	fmt.Println("HONGDA_CHECK_OK")
	return nil
}

func runService(config string) error {
	files, err := ensureRuntime()
	if err != nil {
		return reportError(errorFrame{Phase: "core_extract", Message: err.Error()}, err)
	}
	absolute, err := filepath.Abs(config)
	if err != nil {
		return reportError(errorFrame{Phase: "config_path", Message: err.Error()}, err)
	}
	if err := runCheck(files, absolute); err != nil {
		return err
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	cmd := exec.CommandContext(ctx, files.Core, "run", "-c", absolute)
	cmd.Dir = files.Dir
	childStdout, err := cmd.StdoutPipe()
	if err != nil {
		return reportError(errorFrame{Phase: "core_pipe", Message: err.Error()}, err)
	}
	childStderr, err := cmd.StderrPipe()
	if err != nil {
		return reportError(errorFrame{Phase: "core_pipe", Message: err.Error()}, err)
	}
	if err := cmd.Start(); err != nil {
		frame := errorFrame{Phase: "core_start", Message: err.Error()}
		return reportError(frame, err)
	}

	job, jobErr := attachKillOnCloseJob(cmd.Process.Pid)
	if jobErr != nil {
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
		frame := errorFrame{
			Phase:   "core_supervision",
			Message: "failed to attach HongdaCore to kill-on-close Job Object",
			Detail:  jobErr.Error(),
		}
		return reportError(frame, fmt.Errorf("%s: %w", frame.Message, jobErr))
	}
	defer job.Close()

	startedAt := time.Now()
	fmt.Printf("HONGDA_READY service=%s core=%s wrapperPid=%d corePid=%d\n", serviceVersion, coreVersion, os.Getpid(), cmd.Process.Pid)

	// Keep stdout reserved for Hongda protocol frames. Upstream logs are sent to
	// stderr so Flutter can collect them without corrupting JSON-line IPC.
	go forward(childStdout, os.Stderr, "[HongdaCore] ")
	go forward(childStderr, os.Stderr, "[HongdaCore] ")

	stop := make(chan struct{})
	exited := make(chan error, 1)
	var once sync.Once
	requestStop := func() { once.Do(func() { close(stop) }) }

	go func() { exited <- cmd.Wait() }()

	var writeMu sync.Mutex
	go ipcLoop(cmd.Process.Pid, absolute, files, startedAt, requestStop, &writeMu)

	signals := make(chan os.Signal, 2)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(signals)

	select {
	case waitErr := <-exited:
		if waitErr != nil {
			code := exitCode(waitErr)
			frame := errorFrame{Phase: "core_exit", Message: "HongdaCore exited unexpectedly", ExitCode: code, Detail: waitErr.Error()}
			return reportError(frame, fmt.Errorf("HongdaCore exited with code %d: %w", code, waitErr))
		}
		return nil
	case <-signals:
		requestStop()
	case <-stop:
	}

	// HongdaCore is supervised as our child and is assigned to a
	// kill-on-close Windows Job Object. If HongdaService itself is terminated,
	// the OS closes the job handle and HongdaCore is terminated with it.
	cancel()
	if cmd.Process != nil {
		_ = cmd.Process.Kill()
	}
	select {
	case <-exited:
	case <-time.After(3 * time.Second):
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
	}
	fmt.Println("HONGDA_STOPPED")
	return nil
}

func ipcLoop(corePID int, config string, files runtimeFiles, startedAt time.Time, requestStop func(), mu *sync.Mutex) {
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		lower := strings.ToLower(line)
		if lower == "stop" || lower == "quit" || lower == "exit" {
			requestStop()
			return
		}
		var req ipcRequest
		if err := json.Unmarshal([]byte(line), &req); err != nil {
			writeIPC(mu, ipcResponse{OK: false, Error: "invalid IPC request: " + err.Error()})
			continue
		}
		method := strings.ToLower(strings.TrimSpace(req.Method))
		switch method {
		case "ping":
			writeIPC(mu, ipcResponse{ID: req.ID, OK: true, Result: map[string]interface{}{
				"pong": true, "wrapperPid": os.Getpid(), "corePid": corePID,
			}})
		case "status":
			writeIPC(mu, ipcResponse{ID: req.ID, OK: true, Result: map[string]interface{}{
				"running":        true,
				"pid":            os.Getpid(),
				"wrapperPid":     os.Getpid(),
				"corePid":        corePID,
				"serviceVersion": serviceVersion,
				"coreVersion":    coreVersion,
				"features":       featureSummary,
				"config":         config,
				"corePath":       files.Core,
				"coreSha256":     files.CoreSHA,
				"startedAt":      startedAt.Format(time.RFC3339),
				"uptimeSeconds":  int64(time.Since(startedAt).Seconds()),
				"ipc":            "stdio-jsonl",
			}})
		case "stop":
			writeIPC(mu, ipcResponse{ID: req.ID, OK: true, Result: map[string]interface{}{"stopping": true}})
			requestStop()
			return
		default:
			writeIPC(mu, ipcResponse{ID: req.ID, OK: false, Error: "unknown method: " + method})
		}
	}
	// When the Flutter UI exits or is replaced by an elevated relaunch, its
	// stdin pipe closes. Treat EOF as a stop request so HongdaService and the
	// supervised HongdaCore process cannot remain orphaned.
	requestStop()
}

func writeIPC(mu *sync.Mutex, response ipcResponse) {
	payload, err := json.Marshal(response)
	if err != nil {
		return
	}
	mu.Lock()
	defer mu.Unlock()
	fmt.Printf("HONGDA_IPC %s\n", payload)
}

func forward(r io.Reader, w io.Writer, prefix string) {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		fmt.Fprintln(w, prefix+scanner.Text())
	}
}

func exitCode(err error) int {
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return exitErr.ExitCode()
	}
	return 1
}

func compact(s string) string {
	fields := strings.Fields(strings.ReplaceAll(strings.ReplaceAll(s, "\r", " "), "\n", " "))
	if len(fields) == 0 {
		return ""
	}
	out := strings.Join(fields, " ")
	if len(out) > 1200 {
		return out[:1200] + "…"
	}
	return out
}
