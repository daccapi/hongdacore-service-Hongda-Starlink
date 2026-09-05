param(
    [string]$OutputDirectory = "",
    [string]$CoreSource = "",
    [switch]$SkipCoreBuild
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$ServiceDir = Join-Path $Root 'service'
$RuntimeService = Join-Path $Root 'runtime\service'
$EmbeddedCore = Join-Path $ServiceDir 'embedded\HongdaCore.exe'

if (-not $SkipCoreBuild) {
    $CoreArguments = @{}
    if (-not [string]::IsNullOrWhiteSpace($CoreSource)) { $CoreArguments.CoreSource = $CoreSource }
    & (Join-Path $PSScriptRoot 'build-core.ps1') @CoreArguments
}

if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
    throw 'Go is not installed or not in PATH. HongdaService wrapper requires Go 1.23+.'
}
if (-not (Test-Path -LiteralPath $EmbeddedCore -PathType Leaf)) {
    throw "Embedded HongdaCore is missing: $EmbeddedCore"
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
if ($size -lt 8MB) {
    throw "HongdaService.exe is unexpectedly small ($size bytes). Embedded HongdaCore may be missing."
}
Write-Host "HongdaService built: $Output"
Write-Host "Size: $([math]::Round($size / 1MB, 2)) MB"
Write-Host 'Core: HongdaCore 1.10.6 (locally built Windows amd64 binary)'
