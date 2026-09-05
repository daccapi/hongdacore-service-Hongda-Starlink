param(
    [switch]$NoZip,
    [switch]$SkipServiceBuild
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
$RuntimeService = Join-Path $Root 'runtime\service'
$ServiceExe = Join-Path $RuntimeService 'HongdaService.exe'

if (-not $SkipServiceBuild) {
    & (Join-Path $PSScriptRoot 'build-service.ps1')
}
if (-not (Test-Path -LiteralPath $ServiceExe -PathType Leaf)) {
    throw "HongdaService.exe is missing: $ServiceExe"
}
$serviceSize = (Get-Item -LiteralPath $ServiceExe).Length
if ($serviceSize -lt 40MB) {
    throw "HongdaService.exe is too small ($serviceSize bytes); bundled core verification failed."
}
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw 'Flutter not found in PATH.'
}

flutter pub get
if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed: $LASTEXITCODE" }
flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw "flutter build windows --release failed: $LASTEXITCODE" }

$ReleaseCandidates = @(
    (Join-Path $Root 'build\windows\x64\runner\Release'),
    (Join-Path $Root 'build\windows\runner\Release')
)
$ReleaseDir = $ReleaseCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -First 1
if (-not $ReleaseDir) { throw 'Flutter reported success, but the Windows Release directory could not be located.' }

$ReleaseServiceDir = Join-Path $ReleaseDir 'runtime\service'
New-Item -ItemType Directory -Force -Path $ReleaseServiceDir | Out-Null
Copy-Item -LiteralPath $ServiceExe -Destination (Join-Path $ReleaseServiceDir 'HongdaService.exe') -Force
$License = Join-Path $RuntimeService 'LICENSE-sing-box.txt'
if (Test-Path -LiteralPath $License) { Copy-Item -LiteralPath $License -Destination (Join-Path $ReleaseServiceDir 'LICENSE-sing-box.txt') -Force }

Write-Host ''
Write-Host 'Build finished: Flutter UI + self-contained HongdaService.exe.'
Write-Host "Release: $ReleaseDir"
Write-Host "Service size: $([math]::Round($serviceSize / 1MB, 2)) MB"

if (-not $NoZip) {
    $DistDir = Join-Path $Root 'dist'
    $DistZip = Join-Path $DistDir 'Hongda-Starlink-V1.6.4-Windows-x64.zip'
    New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
    if (Test-Path -LiteralPath $DistZip) { Remove-Item -LiteralPath $DistZip -Force }
    Compress-Archive -Path (Join-Path $ReleaseDir '*') -DestinationPath $DistZip -CompressionLevel Optimal -Force
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($DistZip)
    try {
        $entry = $archive.Entries | Where-Object { $_.FullName.Replace('\','/') -eq 'runtime/service/HongdaService.exe' } | Select-Object -First 1
        if (-not $entry) { throw 'Distribution ZIP verification failed: HongdaService.exe missing.' }
        if ($entry.Length -lt 40MB) { throw "Distribution ZIP verification failed: HongdaService.exe only $($entry.Length) bytes." }
    }
    finally { $archive.Dispose() }
    Write-Host "Package: $DistZip"
}
