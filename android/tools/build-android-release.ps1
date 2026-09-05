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

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw ("Command failed ({0}): {1} {2}" -f $LASTEXITCODE, $FilePath, ($Arguments -join ' '))
    }
}

Invoke-NativeChecked flutter pub get
if ($AllAbis) {
    Invoke-NativeChecked flutter build apk --release
} else {
    Invoke-NativeChecked flutter build apk --release --target-platform android-arm64
}

$apkDir = Join-Path $root 'build\app\outputs\flutter-apk'
$apks = @(Get-ChildItem -Path $apkDir -Filter '*.apk' -File -ErrorAction SilentlyContinue)
if ($apks.Count -eq 0) {
    throw ("Flutter returned success but no APK was found under {0}" -f $apkDir)
}

Write-Host ''
Write-Host 'Android release build finished.'
Write-Host ("APK output: {0}" -f $apkDir)
foreach ($apk in $apks) {
    Write-Host ("APK: {0} ({1:N2} MB)" -f $apk.FullName, ($apk.Length / 1MB))
}
