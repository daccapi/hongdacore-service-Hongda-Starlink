param(
    [string]$Output = ".\dist\HongdaCore.exe",
    [string]$GoToolchain = "go1.25.0"
)

$ErrorActionPreference = "Stop"
$previousToolchain = $env:GOTOOLCHAIN
try {
    $env:GOTOOLCHAIN = $GoToolchain
    $version = (& go version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $version -notmatch [regex]::Escape($GoToolchain)) {
        throw "Expected $GoToolchain, got: $version"
    }

    & go vet ./...
    if ($LASTEXITCODE -ne 0) { throw "go vet failed" }
    & go test ./...
    if ($LASTEXITCODE -ne 0) { throw "go test failed" }

    $absoluteOutput = [System.IO.Path]::GetFullPath($Output)
    $outputDirectory = Split-Path -Parent $absoluteOutput
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    & go build -trimpath -ldflags "-s -w -buildid=" -o $absoluteOutput .\cmd\hongda-core
    if ($LASTEXITCODE -ne 0) { throw "go build failed" }

    & $absoluteOutput version
    & $absoluteOutput features
    Get-FileHash -Algorithm SHA256 -LiteralPath $absoluteOutput
}
finally {
    if ($null -eq $previousToolchain) {
        Remove-Item Env:GOTOOLCHAIN -ErrorAction SilentlyContinue
    }
    else {
        $env:GOTOOLCHAIN = $previousToolchain
    }
}
