param(
    [string]$Output = ".\dist\HongdaCore.exe",
    [string]$GoToolchain = "go1.25.0"
)

$ErrorActionPreference = "Stop"
$previousToolchain = $env:GOTOOLCHAIN
$previousGoWork = $env:GOWORK
$previousCGO = $env:CGO_ENABLED
$previousGOOS = $env:GOOS
$previousGOARCH = $env:GOARCH
try {
    $env:GOTOOLCHAIN = $GoToolchain
    $env:GOWORK = 'off'
    $env:CGO_ENABLED = '0'
    $env:GOOS = 'windows'
    $env:GOARCH = 'amd64'
    $version = (& go version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $version -notmatch [regex]::Escape($GoToolchain)) {
        throw "Expected $GoToolchain, got: $version"
    }

    & go vet -tags with_gvisor ./...
    if ($LASTEXITCODE -ne 0) { throw "go vet failed" }
    & go test -tags with_gvisor ./...
    if ($LASTEXITCODE -ne 0) { throw "go test failed" }

    $absoluteOutput = [System.IO.Path]::GetFullPath($Output)
    $outputDirectory = Split-Path -Parent $absoluteOutput
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    & go build -tags with_gvisor -trimpath -ldflags "-s -w -buildid=" -o $absoluteOutput .\cmd\hongda-core
    if ($LASTEXITCODE -ne 0) { throw "go build failed" }

    & $absoluteOutput version
    & $absoluteOutput features
    Get-FileHash -Algorithm SHA256 -LiteralPath $absoluteOutput
}
finally {
    function Restore-EnvironmentValue([string]$Name, $Value) {
        if ($null -eq $Value) {
            Remove-Item ("Env:" + $Name) -ErrorAction SilentlyContinue
        } else {
            Set-Item ("Env:" + $Name) $Value
        }
    }
    Restore-EnvironmentValue 'GOTOOLCHAIN' $previousToolchain
    Restore-EnvironmentValue 'GOWORK' $previousGoWork
    Restore-EnvironmentValue 'CGO_ENABLED' $previousCGO
    Restore-EnvironmentValue 'GOOS' $previousGOOS
    Restore-EnvironmentValue 'GOARCH' $previousGOARCH
}
