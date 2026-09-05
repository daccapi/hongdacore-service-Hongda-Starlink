param(
    [switch]$SkipCoreBuild,
    [switch]$AllAbis
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if (-not $SkipCoreBuild) {
    & (Join-Path $PSScriptRoot 'build-android-core.ps1') -AllAbis:$AllAbis
}

$coreAar = Join-Path $root 'android\app\libs\HongdaCore.aar'
if (!(Test-Path $coreAar)) {
    throw 'HongdaCore.aar missing. Run tools\build-android-core.ps1 first.'
}

flutter pub get
if ($AllAbis) {
    flutter build apk --release
} else {
    flutter build apk --release --target-platform android-arm64
}

Write-Host ''
Write-Host 'Android release build finished.'
Write-Host ("APK output: {0}" -f (Join-Path $root 'build\app\outputs\flutter-apk'))
