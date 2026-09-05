param(
    [switch]$AllAbis,
    [switch]$SkipToolInstall
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$core = Join-Path $root 'core\sing-box'
$outDir = Join-Path $root 'android\app\libs'
$outAar = Join-Path $outDir 'HongdaCore.aar'

if (-not (Test-Path (Join-Path $core 'go.mod'))) {
    throw "sing-box source missing: $core"
}

if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
    throw 'Go not found. Go 1.24.7+ is required (Go 1.26.x is OK).'
}

if (-not $env:ANDROID_HOME -and -not $env:ANDROID_SDK_ROOT) {
    $defaultSdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
    if (Test-Path $defaultSdk) {
        $env:ANDROID_HOME = $defaultSdk
        $env:ANDROID_SDK_ROOT = $defaultSdk
    }
}
if (-not $env:ANDROID_HOME -and $env:ANDROID_SDK_ROOT) { $env:ANDROID_HOME = $env:ANDROID_SDK_ROOT }
if (-not $env:ANDROID_SDK_ROOT -and $env:ANDROID_HOME) { $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME }
if (-not $env:ANDROID_HOME -or -not (Test-Path $env:ANDROID_HOME)) {
    throw 'Android SDK not found. Install Android Studio/SDK or set ANDROID_HOME.'
}

$goBin = Join-Path (go env GOPATH) 'bin'
$gomobile = Join-Path $goBin 'gomobile.exe'
$gobind = Join-Path $goBin 'gobind.exe'
if (-not $SkipToolInstall -and (!(Test-Path $gomobile) -or !(Test-Path $gobind))) {
    Write-Host 'Installing SagerNet gomobile v0.1.12...'
    go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.12
    go install github.com/sagernet/gomobile/cmd/gobind@v0.1.12
}
if (!(Test-Path $gomobile) -or !(Test-Path $gobind)) {
    throw "gomobile/gobind not found in $goBin"
}

New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$platform = if ($AllAbis) { 'android' } else { 'android/arm64' }

Push-Location $core
try {
    Write-Host "Building HongdaCore.aar ($platform) from sing-box v1.13.18..."
    go run ./cmd/internal/build_hongdacore -platform $platform -output $outAar
} finally {
    Pop-Location
}

if (!(Test-Path $outAar)) { throw 'HongdaCore.aar was not produced.' }

$entries = & jar tf $outAar
if ($LASTEXITCODE -ne 0) {
    throw 'AAR validation failed: unable to list HongdaCore.aar.'
}
if (-not ($entries -match '^classes\.jar$')) {
    throw 'AAR validation failed: classes.jar missing.'
}
if (-not ($entries -match '(^|/)libhongdacore\.so$')) {
    throw 'AAR validation failed: libhongdacore.so missing.'
}

# Java bytecode lives inside classes.jar, not at the AAR root. Validate the
# generated Hongda package by inspecting the nested JAR instead of searching
# the outer AAR listing.
$validationDir = Join-Path ([System.IO.Path]::GetTempPath()) ("hongda-aar-validate-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $validationDir | Out-Null
Push-Location $validationDir
try {
    & jar xf $outAar classes.jar
    if ($LASTEXITCODE -ne 0 -or !(Test-Path (Join-Path $validationDir 'classes.jar'))) {
        throw 'AAR validation failed: unable to extract classes.jar.'
    }
    $classEntries = & jar tf (Join-Path $validationDir 'classes.jar')
    if ($LASTEXITCODE -ne 0) {
        throw 'AAR validation failed: unable to list classes.jar.'
    }
    if (-not ($classEntries -match '^com/hongda/starlink/core/libbox/Libbox\.class$')) {
        throw 'AAR validation failed: com.hongda.starlink.core.libbox.Libbox.class missing.'
    }
} finally {
    Pop-Location
    Remove-Item -Recurse -Force $validationDir -ErrorAction SilentlyContinue
}

$size = (Get-Item $outAar).Length / 1MB
Write-Host ("HongdaCore built: {0}" -f $outAar)
Write-Host ("Size: {0:N2} MB" -f $size)
Write-Host 'Java package: com.hongda.starlink.core.libbox'
Write-Host 'Native library: libhongdacore.so'
