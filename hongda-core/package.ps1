$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path
$parent = Split-Path -Parent $root
$ver = '1.4.1'

$stage = Join-Path $env:TEMP ("hongda-core-" + [guid]::NewGuid().ToString('N'))
$binDir = Join-Path $stage 'bin'
$srcDir = Join-Path $stage 'src'
New-Item -ItemType Directory -Force -Path $binDir, $srcDir | Out-Null

# Binary package: executable plus user-facing docs.
Get-ChildItem -Path (Join-Path $root 'docs') -File | Copy-Item -Destination $binDir -Force
Copy-Item -LiteralPath (Join-Path $root 'HongdaCore.exe') -Destination $binDir -Force
Copy-Item -LiteralPath (Join-Path $root 'CHANGELOG.md') -Destination $binDir -Force
Copy-Item -LiteralPath (Join-Path $root 'NOTICE.md') -Destination $binDir -Force
Copy-Item -LiteralPath (Join-Path $root 'README.md') -Destination $binDir -Force
Copy-Item -LiteralPath (Join-Path $root 'smoke-test.ps1') -Destination $binDir -Force
Copy-Item -LiteralPath (Join-Path $root 'test-config.json') -Destination $binDir -Force

# Source package: everything except the nested Starlink source and generated exe.
$exclude = '*\Hongda-Starlink-V1.6.8-Windows-Source\*'
Get-ChildItem -Path $root -Recurse -File |
  Where-Object { $_.FullName -notlike $exclude -and $_.Name -ne 'HongdaCore.exe' } |
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

Remove-Item -LiteralPath $stage -Recurse -Force

Get-ChildItem -LiteralPath $parent -Filter ("*HongdaCore-{0}*" -f $ver) |
  Select-Object Name, Length
Get-Content -LiteralPath $sums
