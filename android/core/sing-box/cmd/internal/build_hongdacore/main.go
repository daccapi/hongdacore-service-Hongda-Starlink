package main

import (
	"flag"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	_ "github.com/sagernet/gomobile"
	"github.com/sagernet/sing-box/cmd/internal/build_shared"
	"github.com/sagernet/sing-box/log"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/shell"
)

var (
	debugEnabled bool
	platform     string
	output       string
)

func init() {
	flag.BoolVar(&debugEnabled, "debug", false, "enable debug")
	flag.StringVar(&platform, "platform", "android/arm64", "gomobile target, e.g. android/arm64 or android")
	flag.StringVar(&output, "output", "HongdaCore.aar", "output AAR path")
}

func main() {
	flag.Parse()
	build_shared.FindMobile()
	build_shared.FindSDK()
	checkJavaVersion()

	currentTag, err := build_shared.ReadTag()
	if err != nil {
		currentTag = "1.13.18-hongda"
	}

	tags := []string{
		"with_gvisor",
		"with_quic",
		"with_wireguard",
		"with_utls",
		"with_naive_outbound",
		"with_clash_api",
		"badlinkname",
		"tfogo_checklinkname0",
		"with_tailscale",
		"ts_omit_logtail",
		"ts_omit_ssh",
		"ts_omit_drive",
		"ts_omit_taildrop",
		"ts_omit_webclient",
		"ts_omit_doctor",
		"ts_omit_capture",
		"ts_omit_kube",
		"ts_omit_aws",
		"ts_omit_synology",
		"ts_omit_bird",
	}
	if debugEnabled {
		tags = append(tags, "debug")
	}

	args := []string{
		"bind",
		"-v",
		"-o", output,
		"-target", platform,
		"-androidapi", strconv.Itoa(24),
		"-javapkg=com.hongda.starlink.core",
		"-libname=hongdacore",
	}

	if debugEnabled {
		args = append(args,
			"-ldflags",
			"-X github.com/sagernet/sing-box/constant.Version="+currentTag+" -X internal/godebug.defaultGODEBUG=multipathtcp=0 -checklinkname=0",
		)
	} else {
		args = append(args,
			"-trimpath",
			"-buildvcs=false",
			"-ldflags",
			"-X github.com/sagernet/sing-box/constant.Version="+currentTag+" -X internal/godebug.defaultGODEBUG=multipathtcp=0 -s -w -buildid= -checklinkname=0",
		)
	}

	args = append(args, "-tags", strings.Join(tags, ","), "./experimental/libbox")

	command := exec.Command(filepath.Join(build_shared.GoBinPath, executableName("gomobile")), args...)
	// Windows cmd.exe injects hidden drive-current-directory variables such as
	// "=C:=C:\\..." (and, in some shells, "=::=::\\"). sagernet/gomobile
	// v0.1.12 preserves them on its first environment merge and then panics when
	// the merged environment is processed a second time. Do not pass these
	// pseudo variables to gomobile; regular environment variables are preserved.
	command.Env = hongdaMobileEnvironment()
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	if err := command.Run(); err != nil {
		log.Fatal(err)
	}

	abs, _ := filepath.Abs(output)
	log.Info("HongdaCore built: ", abs)
	log.Info("Java package prefix: com.hongda.starlink.core")
	log.Info("Native library: libhongdacore.so")
}

func hongdaMobileEnvironment() []string {
	environment := os.Environ()
	clean := make([]string, 0, len(environment))
	for _, entry := range environment {
		// Windows has special pseudo environment variables whose names begin
		// with '='. They are not needed by Go/NDK tooling and trigger a panic
		// in gomobile v0.1.12 when its environment is merged twice.
		if strings.HasPrefix(entry, "=") {
			continue
		}
		clean = append(clean, entry)
	}
	return clean
}

func executableName(name string) string {
	if strings.EqualFold(filepath.Ext(os.Args[0]), ".exe") || strings.EqualFold(os.Getenv("OS"), "Windows_NT") {
		return name + ".exe"
	}
	return name
}

func checkJavaVersion() {
	javaPath := "java"
	if javaHome := os.Getenv("JAVA_HOME"); javaHome != "" {
		javaPath = filepath.Join(javaHome, "bin", executableName("java"))
	}
	version, err := shell.Exec(javaPath, "--version").ReadOutput()
	if err != nil {
		log.Fatal(E.Cause(err, "check java version"))
	}
	// Android/AGP requires Java 17+. Accept newer JDKs instead of the upstream
	// exact-17 restriction so Android Studio JBR 21 can also build HongdaCore.
	if !(strings.Contains(version, " 17.") || strings.Contains(version, " 18.") ||
		strings.Contains(version, " 19.") || strings.Contains(version, " 20.") ||
		strings.Contains(version, " 21.") || strings.Contains(version, " 22.") ||
		strings.Contains(version, " 23.") || strings.Contains(version, " 24.") ||
		strings.Contains(version, " 25.") || strings.Contains(version, " 26.")) {
		log.Fatal("Java 17 or newer is required")
	}
}
