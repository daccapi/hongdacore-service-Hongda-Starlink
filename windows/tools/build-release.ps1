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
if ($serviceSize -lt 8MB) {
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
Copy-Item -LiteralPath (Join-Path $Root 'README.md') -Destination (Join-Path $ReleaseDir 'README.md') -Force
Copy-Item -LiteralPath (Join-Path $Root 'CHANGELOG.md') -Destination (Join-Path $ReleaseDir 'CHANGELOG.md') -Force
$NoticeItems = @('NOTICE.md', 'GPL-3.0.txt', 'Wintun-prebuilt-LICENSE.txt')
foreach ($NoticeName in $NoticeItems) {
    $Notice = Join-Path $RuntimeService $NoticeName
    if (Test-Path -LiteralPath $Notice) {
        Copy-Item -LiteralPath $Notice -Destination (Join-Path $ReleaseServiceDir $NoticeName) -Force
    }
}

# Flutter's MSVC runner links dynamically against the Microsoft VC runtime.
# A developer machine already has these DLLs, but a clean target machine may
# not. Bundle them next to the executable so the release is self-contained.
$VcRuntimeCandidates = @()
$VsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path -LiteralPath $VsWhere) {
    $VsInstall = & $VsWhere -latest -products * -property installationPath 2>$null
    if ($VsInstall) {
        $VcRuntimeCandidates += Get-ChildItem -Path (Join-Path $VsInstall 'VC\Redist\MSVC') -Recurse -Filter 'vcruntime140.dll' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty DirectoryName
    }
}
$VcRuntimeCandidates += Join-Path $env:WINDIR 'System32'
$VcDlls = @('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll')
foreach ($Candidate in ($VcRuntimeCandidates | Select-Object -Unique)) {
    foreach ($Dll in $VcDlls) {
        $Source = Join-Path $Candidate $Dll
        if (Test-Path -LiteralPath $Source) {
            Copy-Item -LiteralPath $Source -Destination (Join-Path $ReleaseDir $Dll) -Force
        }
    }
}

Write-Host ''
Write-Host 'Build finished: Flutter UI + self-contained HongdaService.exe.'
Write-Host "Release: $ReleaseDir"
Write-Host "Service size: $([math]::Round($serviceSize / 1MB, 2)) MB"

if (-not $NoZip) {
    $DistDir = Split-Path -Parent $Root
    $DistZip = Join-Path $DistDir 'Hongda-Starlink-V1.6.13-Windows-x64.zip'
    New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
    if (Test-Path -LiteralPath $DistZip) { Remove-Item -LiteralPath $DistZip -Force }
    Compress-Archive -Path (Join-Path $ReleaseDir '*') -DestinationPath $DistZip -CompressionLevel Optimal -Force
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($DistZip)
    try {
        $entry = $archive.Entries | Where-Object { $_.FullName.Replace('\','/') -eq 'runtime/service/HongdaService.exe' } | Select-Object -First 1
        if (-not $entry) { throw 'Distribution ZIP verification failed: HongdaService.exe missing.' }
        if ($entry.Length -lt 8MB) { throw "Distribution ZIP verification failed: HongdaService.exe only $($entry.Length) bytes." }
    }
    finally { $archive.Dispose() }
    Write-Host "Package: $DistZip"
}
