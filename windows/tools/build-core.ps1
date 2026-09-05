param(
    [string]$CoreSource = "",
    [string]$GoToolchain = "go1.25.0"
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Output = Join-Path $Root 'service\embedded\HongdaCore.exe'
$LocalSource = Join-Path $Root 'third_party\hongda-core'
$SiblingCandidates = @(
    (Join-Path (Split-Path -Parent $Root) 'hongda-core'),
    (Join-Path (Split-Path -Parent (Split-Path -Parent $Root)) 'hongda-core')
)
$CoreVersion = '1.10.9'
$BuildTags = 'with_gvisor'

if ([string]::IsNullOrWhiteSpace($CoreSource)) {
    $SiblingSource = $SiblingCandidates | Where-Object {
            Test-Path -LiteralPath (Join-Path $_ 'go.mod') -PathType Leaf
        } | Select-Object -First 1
    if ($SiblingSource) {
        $CoreSource = $SiblingSource
    } elseif (Test-Path -LiteralPath (Join-Path $LocalSource 'go.mod') -PathType Leaf) {
        $CoreSource = $LocalSource
    } else {
        throw 'HongdaCore source was not found. Pass -CoreSource or keep hongda-core beside this Windows project.'
    }
}

$CoreSource = (Resolve-Path -LiteralPath $CoreSource).Path
if (-not (Test-Path -LiteralPath (Join-Path $CoreSource 'go.mod') -PathType Leaf)) {
    throw "Invalid HongdaCore source directory: $CoreSource"
}
if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
    throw 'Go is not installed or not in PATH. HongdaCore requires Go 1.25+.'
}

$OutputDir = Split-Path -Parent $Output
$TemporaryOutput = Join-Path $OutputDir 'HongdaCore.build.exe'
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
Remove-Item -LiteralPath $TemporaryOutput -Force -ErrorAction SilentlyContinue

Write-Host "Building HongdaCore $CoreVersion from local source: $CoreSource"
Push-Location $CoreSource
$PreviousToolchain = $env:GOTOOLCHAIN
try {
    $env:GOTOOLCHAIN = $GoToolchain
    $env:GOWORK = 'off'
    $env:CGO_ENABLED = '0'
    $env:GOOS = 'windows'
    $env:GOARCH = 'amd64'
    $GoVersion = (& go version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $GoVersion -notmatch [regex]::Escape($GoToolchain)) {
        throw "Expected $GoToolchain, got: $GoVersion"
    }
    $LinkFlags = '-s -w -buildid='
    & go build -trimpath -tags $BuildTags -ldflags $LinkFlags -o $TemporaryOutput .\cmd\hongda-core
    if ($LASTEXITCODE -ne 0) { throw "HongdaCore build failed: $LASTEXITCODE" }
} finally {
    Pop-Location
    Remove-Item Env:GOWORK -ErrorAction SilentlyContinue
    Remove-Item Env:CGO_ENABLED -ErrorAction SilentlyContinue
    Remove-Item Env:GOOS -ErrorAction SilentlyContinue
    Remove-Item Env:GOARCH -ErrorAction SilentlyContinue
    if ($null -eq $PreviousToolchain) {
        Remove-Item Env:GOTOOLCHAIN -ErrorAction SilentlyContinue
    } else {
        $env:GOTOOLCHAIN = $PreviousToolchain
    }
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
$RuntimeService = Join-Path $Root 'runtime\service'
New-Item -ItemType Directory -Force -Path $RuntimeService | Out-Null
foreach ($NoticeName in @('NOTICE.md', 'GPL-3.0.txt', 'Wintun-prebuilt-LICENSE.txt')) {
    $NoticeSource = if ($NoticeName -eq 'NOTICE.md') {
        Join-Path $CoreSource $NoticeName
    } else {
        Join-Path (Join-Path $CoreSource 'licenses') $NoticeName
    }
    if (-not (Test-Path -LiteralPath $NoticeSource -PathType Leaf)) {
        throw "Required third-party notice is missing: $NoticeSource"
    }
    Copy-Item -LiteralPath $NoticeSource -Destination (Join-Path $RuntimeService $NoticeName) -Force
}
Write-Host "HongdaCore built: $Output"
Write-Host "Version: $CoreVersion"
Write-Host "Size: $([math]::Round($Size / 1MB, 2)) MB"
