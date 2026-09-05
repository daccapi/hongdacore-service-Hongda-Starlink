param(
    [string]$CoreSource = ""
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Output = Join-Path $Root 'service\embedded\HongdaCore.exe'
$LocalSource = Join-Path $Root 'third_party\sing-box'
$SiblingSource = Join-Path (Split-Path -Parent $Root) 'Hongda-Starlink-V1.6.4-R2-Android-CoreBridge-R9-KaringCompat-Source\core\sing-box'
$CoreVersion = '1.13.18'
$BuildTags = 'with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_acme,with_clash_api,with_tailscale,with_ccm,with_ocm,with_naive_outbound,with_purego,badlinkname,tfogo_checklinkname0'

if ([string]::IsNullOrWhiteSpace($CoreSource)) {
    if (Test-Path -LiteralPath (Join-Path $LocalSource 'go.mod') -PathType Leaf) {
        $CoreSource = $LocalSource
    } elseif (Test-Path -LiteralPath (Join-Path $SiblingSource 'go.mod') -PathType Leaf) {
        $CoreSource = $SiblingSource
    } else {
        throw 'HongdaCore source was not found. Pass -CoreSource or keep the Android R9 source beside this Windows project.'
    }
}

$CoreSource = (Resolve-Path -LiteralPath $CoreSource).Path
if (-not (Test-Path -LiteralPath (Join-Path $CoreSource 'go.mod') -PathType Leaf)) {
    throw "Invalid HongdaCore source directory: $CoreSource"
}
if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
    throw 'Go is not installed or not in PATH. HongdaCore requires Go 1.24.7+.'
}

$OutputDir = Split-Path -Parent $Output
$TemporaryOutput = Join-Path $OutputDir 'HongdaCore.build.exe'
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
Remove-Item -LiteralPath $TemporaryOutput -Force -ErrorAction SilentlyContinue

Write-Host "Building HongdaCore $CoreVersion from local source: $CoreSource"
Push-Location $CoreSource
try {
    $env:GOWORK = 'off'
    $env:CGO_ENABLED = '0'
    $env:GOOS = 'windows'
    $env:GOARCH = 'amd64'
    $LinkFlags = "-X github.com/sagernet/sing-box/constant.Version=$CoreVersion -s -w -buildid= -checklinkname=0"
    & go build -trimpath -tags $BuildTags -ldflags $LinkFlags -o $TemporaryOutput .\cmd\sing-box
    if ($LASTEXITCODE -ne 0) { throw "HongdaCore build failed: $LASTEXITCODE" }
} finally {
    Pop-Location
    Remove-Item Env:GOWORK -ErrorAction SilentlyContinue
    Remove-Item Env:CGO_ENABLED -ErrorAction SilentlyContinue
    Remove-Item Env:GOOS -ErrorAction SilentlyContinue
    Remove-Item Env:GOARCH -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $TemporaryOutput -PathType Leaf)) {
    throw "HongdaCore.exe was not produced: $TemporaryOutput"
}
$VersionOutput = (& $TemporaryOutput version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $VersionOutput -notmatch [regex]::Escape($CoreVersion)) {
    Remove-Item -LiteralPath $TemporaryOutput -Force -ErrorAction SilentlyContinue
    throw "HongdaCore version validation failed: $VersionOutput"
}

Move-Item -LiteralPath $TemporaryOutput -Destination $Output -Force
$Size = (Get-Item -LiteralPath $Output).Length
Write-Host "HongdaCore built: $Output"
Write-Host "Version: $CoreVersion"
Write-Host "Size: $([math]::Round($Size / 1MB, 2)) MB"

