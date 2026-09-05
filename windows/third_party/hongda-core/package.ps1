$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path
$parent = Split-Path -Parent $root
$ver = '1.10.4'

& (Join-Path $root 'build-windows.ps1') -Output (Join-Path $root 'dist\HongdaCore.exe')

$stage = Join-Path $env:TEMP ("hongda-core-" + [guid]::NewGuid().ToString('N'))
$binDir = Join-Path $stage 'bin'
$srcDir = Join-Path $stage 'src'
New-Item -ItemType Directory -Force -Path $binDir, $srcDir | Out-Null
$licenseDir = Join-Path $binDir 'licenses'
New-Item -ItemType Directory -Force -Path $licenseDir | Out-Null

# Binary package: executable plus user-facing docs.
Get-ChildItem -Path (Join-Path $root 'docs') -File | Copy-Item -Destination $binDir -Force
Copy-Item -LiteralPath (Join-Path $root 'dist\HongdaCore.exe') -Destination (Join-Path $binDir 'HongdaCore.exe') -Force
Copy-Item -LiteralPath (Join-Path $root 'CHANGELOG.md') -Destination $binDir -Force
Copy-Item -LiteralPath (Join-Path $root 'NOTICE.md') -Destination $binDir -Force
Copy-Item -LiteralPath (Join-Path $root 'README.md') -Destination $binDir -Force
Copy-Item -LiteralPath (Join-Path $root 'smoke-test.ps1') -Destination $binDir -Force
Copy-Item -LiteralPath (Join-Path $root 'test-config.json') -Destination $binDir -Force
Get-ChildItem -Path (Join-Path $root 'licenses') -File | Copy-Item -Destination $licenseDir -Force

$moduleCache = (& go env GOMODCACHE 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $moduleCache)) {
  throw "Unable to locate Go module cache for third-party licenses"
}
$singTunModule = Get-ChildItem -Path (Join-Path $moduleCache 'github.com\sagernet') -Directory -Filter 'sing-tun@v0.8.12-*' |
  Sort-Object Name -Descending | Select-Object -First 1
$gvisorModule = Get-ChildItem -Path (Join-Path $moduleCache 'github.com\sagernet') -Directory -Filter 'gvisor@v0.0.0-*' |
  Sort-Object Name -Descending | Select-Object -First 1
if ($null -eq $singTunModule -or $null -eq $gvisorModule) {
  throw "Required sing-tun/gVisor license files are unavailable"
}
Copy-Item -LiteralPath (Join-Path $singTunModule.FullName 'LICENSE') -Destination (Join-Path $licenseDir 'sing-tun-GPL-3.0.txt') -Force
Copy-Item -LiteralPath (Join-Path $gvisorModule.FullName 'LICENSE') -Destination (Join-Path $licenseDir 'gVisor-Apache-2.0.txt') -Force
Copy-Item -LiteralPath (Join-Path $gvisorModule.FullName 'AUTHORS') -Destination (Join-Path $licenseDir 'gVisor-AUTHORS.txt') -Force

# Source package: everything except the nested Starlink reference tree and
# generated binaries. The nested tree is deliberately kept locally as a
# reference but must not inflate or contaminate the standalone Core source.
$exclude = '*\Hongda-Starlink-V1.6.8-Windows-Source\*'
Get-ChildItem -Path $root -Recurse -File |
  Where-Object {
    $_.FullName -notlike $exclude -and
    $_.FullName -notlike (Join-Path $root 'dist\*') -and
    $_.Name -ne 'HongdaCore.exe'
  } |
  ForEach-Object {
    $rel = $_.FullName.Substring($root.Length).TrimStart('\', '/')
    $dest = Join-Path $srcDir $rel
    $dir = Split-Path -Parent $dest
    if ($dir -and -not (Test-Path $dir)) {
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
  }

$binZip = Join-Path $parent ("HongdaCore-{0}-Windows-x64.zip" -f $ver)
$srcZip = Join-Path $parent ("HongdaCore-{0}-Source.zip" -f $ver)
if (Test-Path $binZip) { Remove-Item -LiteralPath $binZip -Force }
if (Test-Path $srcZip) { Remove-Item -LiteralPath $srcZip -Force }

Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($binDir, $binZip, [System.IO.Compression.CompressionLevel]::Optimal, $false)
[System.IO.Compression.ZipFile]::CreateFromDirectory($srcDir, $srcZip, [System.IO.Compression.CompressionLevel]::Optimal, $false)

$sums = Join-Path $parent ("SHA256SUMS-HongdaCore-{0}.txt" -f $ver)
$lines = @()
foreach ($file in @($srcZip, $binZip)) {
  $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash.ToUpperInvariant()
  $lines += ("{0} *{1}" -f $hash, (Split-Path -Leaf $file))
}
Set-Content -LiteralPath $sums -Value $lines -Encoding ascii

$resolvedTemp = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
$resolvedStage = [System.IO.Path]::GetFullPath($stage)
if (-not $resolvedStage.StartsWith($resolvedTemp, [System.StringComparison]::OrdinalIgnoreCase) -or
    (Split-Path -Leaf $resolvedStage) -notlike 'hongda-core-*') {
  throw "Refusing to remove unexpected staging path: $resolvedStage"
}
Remove-Item -LiteralPath $resolvedStage -Recurse -Force

Get-ChildItem -LiteralPath $parent -Filter ("*HongdaCore-{0}*" -f $ver) |
  Select-Object Name, Length
Get-Content -LiteralPath $sums
