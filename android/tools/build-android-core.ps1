param(
    [switch]$AllAbis,
    [switch]$SkipToolInstall
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$core = Join-Path $root 'core\sing-box'
$outDir = Join-Path $root 'android\app\libs'
$outAar = Join-Path $outDir 'HongdaCore.aar'
$buildId = 'V1.6.4-R2-Android-CoreBridge-R5-KotlinFix-20260813'

Write-Host ("Hongda Android Core Build: {0}" -f $buildId)

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

function Install-HongdaPatchedGomobile {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$GoBin
    )

    if ($env:OS -ne 'Windows_NT') { return }

    $patchRoot = Join-Path $Root '.hongda-tools\gomobile-v0.1.12-patched'
    $marker = Join-Path $patchRoot 'HONGDA_PATCHED.txt'
    $gomobileExe = Join-Path $GoBin 'gomobile.exe'
    $gobindExe = Join-Path $GoBin 'gobind.exe'

    if ((Test-Path $marker) -and (Test-Path $gomobileExe) -and (Test-Path $gobindExe)) {
        Write-Host 'Using previously installed Hongda-patched gomobile v0.1.12.'
        return
    }

    Write-Host 'Preparing Hongda-patched SagerNet gomobile v0.1.12 for Windows...'
    Invoke-NativeChecked go mod download github.com/sagernet/gomobile@v0.1.12

    $goModCache = (go env GOMODCACHE).Trim()
    if ([string]::IsNullOrWhiteSpace($goModCache)) {
        throw 'Unable to resolve Go module cache.'
    }
    $moduleRoot = Join-Path $goModCache 'github.com\sagernet\gomobile@v0.1.12'
    if (!(Test-Path $moduleRoot)) {
        throw ("gomobile v0.1.12 source not found in module cache: {0}" -f $moduleRoot)
    }

    if (Test-Path $patchRoot) {
        Remove-Item -Recurse -Force $patchRoot
    }
    New-Item -ItemType Directory -Force -Path $patchRoot | Out-Null
    Copy-Item -Path (Join-Path $moduleRoot '*') -Destination $patchRoot -Recurse -Force
    Get-ChildItem -Path $patchRoot -Recurse -File | ForEach-Object {
        try { $_.IsReadOnly = $false } catch { }
    }

    $envGo = Join-Path $patchRoot 'cmd\gomobile\env.go'
    $source = [System.IO.File]::ReadAllText($envGo)
    $pattern = 'for _, ev := range kv \{\r?\n\t\telem := strings\.SplitN\(ev, "=", 2\)\r?\n\t\tif len\(elem\) != 2 \|\| elem\[0\] == "" \{\r?\n\t\t\tpanic\(fmt\.Sprintf\("malformed env var %q from input", ev\)\)\r?\n\t\t\}'
    $replacement = @"
for _, ev := range kv {
        elem := strings.SplitN(ev, "=", 2)
        if len(elem) != 2 || elem[0] == "" {
            // Hongda Windows fix: cmd.exe may inject pseudo environment
            // variables such as "=C:=C:\\\\..." or "=::=::\\\\". environ()
            // can be called twice, so preserve these entries instead of
            // panicking during the second merge.
            new = append(new, ev)
            continue
        }
"@
    $patched = [regex]::Replace($source, $pattern, $replacement, 1)
    if ($patched -eq $source) {
        throw 'Unable to apply Hongda gomobile Windows environment patch.'
    }
    [System.IO.File]::WriteAllText($envGo, $patched, (New-Object System.Text.UTF8Encoding($false)))

    Push-Location $patchRoot
    try {
        Invoke-NativeChecked go install .\cmd\gomobile
        Invoke-NativeChecked go install .\cmd\gobind
    } finally {
        Pop-Location
    }

    Set-Content -Path $marker -Value $buildId -Encoding ASCII
    Write-Host 'Hongda-patched gomobile installed.'
}

if (-not (Test-Path (Join-Path $core 'go.mod'))) {
    throw "sing-box source missing: $core"
}

if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
    throw 'Go not found. Go 1.24.7+ is required (Go 1.26.x is OK).'
}

if (-not $env:ANDROID_HOME -and -not $env:ANDROID_SDK_ROOT) {
    $defaultSdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
    if (Test-Path $defaultSdk) {
        $env:ANDROID_HOME = $defaultSdk
        $env:ANDROID_SDK_ROOT = $defaultSdk
    }
}
if (-not $env:ANDROID_HOME -and $env:ANDROID_SDK_ROOT) { $env:ANDROID_HOME = $env:ANDROID_SDK_ROOT }
if (-not $env:ANDROID_SDK_ROOT -and $env:ANDROID_HOME) { $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME }
if (-not $env:ANDROID_HOME -or -not (Test-Path $env:ANDROID_HOME)) {
    throw 'Android SDK not found. Install Android Studio/SDK or set ANDROID_HOME.'
}

$goBin = Join-Path (go env GOPATH) 'bin'
$gomobile = Join-Path $goBin 'gomobile.exe'
$gobind = Join-Path $goBin 'gobind.exe'

if (-not $SkipToolInstall) {
    Install-HongdaPatchedGomobile -Root $root -GoBin $goBin
} elseif (!(Test-Path $gomobile) -or !(Test-Path $gobind)) {
    throw "gomobile/gobind not found in $goBin"
}

New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$platform = if ($AllAbis) { 'android' } else { 'android/arm64' }

# Never validate a stale/empty AAR left by a failed gomobile run.
Remove-Item -Force $outAar -ErrorAction SilentlyContinue

Push-Location $core
try {
    Write-Host "Building HongdaCore.aar ($platform) from sing-box v1.13.18..."
    & go run ./cmd/internal/build_hongdacore -platform $platform -output $outAar
    if ($LASTEXITCODE -ne 0) {
        throw ("HongdaCore gomobile build failed with exit code {0}." -f $LASTEXITCODE)
    }
} finally {
    Pop-Location
}

if (!(Test-Path $outAar)) { throw 'HongdaCore.aar was not produced.' }
if ((Get-Item $outAar).Length -le 0) { throw 'HongdaCore.aar is empty.' }

$entries = & jar tf $outAar
if ($LASTEXITCODE -ne 0) {
    throw 'AAR validation failed: unable to list HongdaCore.aar.'
}
if (-not ($entries -match '^classes\.jar$')) {
    throw 'AAR validation failed: classes.jar missing.'
}
if (-not ($entries -match '(^|/)libhongdacore\.so$')) {
    throw 'AAR validation failed: libhongdacore.so missing.'
}

$validationDir = Join-Path ([System.IO.Path]::GetTempPath()) ("hongda-aar-validate-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $validationDir | Out-Null
Push-Location $validationDir
try {
    & jar xf $outAar classes.jar
    if ($LASTEXITCODE -ne 0 -or !(Test-Path (Join-Path $validationDir 'classes.jar'))) {
        throw 'AAR validation failed: unable to extract classes.jar.'
    }
    $classEntries = & jar tf (Join-Path $validationDir 'classes.jar')
    if ($LASTEXITCODE -ne 0) {
        throw 'AAR validation failed: unable to list classes.jar.'
    }
    if (-not ($classEntries -match '^com/hongda/starlink/core/libbox/Libbox\.class$')) {
        throw 'AAR validation failed: com.hongda.starlink.core.libbox.Libbox.class missing.'
    }
} finally {
    Pop-Location
    Remove-Item -Recurse -Force $validationDir -ErrorAction SilentlyContinue
}

$size = (Get-Item $outAar).Length / 1MB
Write-Host ("HongdaCore built: {0}" -f $outAar)
Write-Host ("Size: {0:N2} MB" -f $size)
Write-Host 'Java package: com.hongda.starlink.core.libbox'
Write-Host 'Native library: libhongdacore.so'
