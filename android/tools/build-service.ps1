param(
    [string]$OutputDirectory = ""
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$ServiceDir = Join-Path $Root 'service'
$RuntimeService = Join-Path $Root 'runtime\service'
$EmbeddedCore = Join-Path $ServiceDir 'embedded\sing-box.exe'
$EmbeddedCronet = Join-Path $ServiceDir 'embedded\libcronet.dll'

if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
    throw 'Go is not installed or not in PATH. HongdaService wrapper requires Go 1.23+.'
}
if (-not (Test-Path -LiteralPath $EmbeddedCore -PathType Leaf)) {
    throw "Embedded sing-box core is missing: $EmbeddedCore"
}
if (-not (Test-Path -LiteralPath $EmbeddedCronet -PathType Leaf)) {
    throw "Embedded libcronet.dll is missing: $EmbeddedCronet"
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = $RuntimeService
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$Output = Join-Path $OutputDirectory 'HongdaService.exe'

Push-Location $ServiceDir
try {
    $env:GOWORK = 'off'
    $env:CGO_ENABLED = '0'
    $env:GOOS = 'windows'
    $env:GOARCH = 'amd64'
    go build -trimpath -ldflags '-s -w -buildid=' -o $Output .
    if ($LASTEXITCODE -ne 0) { throw "HongdaService build failed: $LASTEXITCODE" }
}
finally {
    Pop-Location
    Remove-Item Env:GOWORK -ErrorAction SilentlyContinue
    Remove-Item Env:CGO_ENABLED -ErrorAction SilentlyContinue
    Remove-Item Env:GOOS -ErrorAction SilentlyContinue
    Remove-Item Env:GOARCH -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $Output -PathType Leaf)) {
    throw "HongdaService.exe was not produced: $Output"
}
$size = (Get-Item -LiteralPath $Output).Length
if ($size -lt 40MB) {
    throw "HongdaService.exe is unexpectedly small ($size bytes). Embedded sing-box may be missing."
}
Write-Host "HongdaService built: $Output"
Write-Host "Size: $([math]::Round($size / 1MB, 2)) MB"
Write-Host 'Core: sing-box 1.13.18 (embedded official Windows amd64 binary)'
