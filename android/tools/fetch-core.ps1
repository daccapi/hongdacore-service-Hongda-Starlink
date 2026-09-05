param(
    [string]$ZipPath = ""
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Destination = Join-Path $Root 'service\embedded'
$ExpectedSha256 = '65045155ffdc506334f01a4353889657ddfc024f72b394081a9abaef34dfbef3'

if ([string]::IsNullOrWhiteSpace($ZipPath)) {
    throw 'Pass the official sing-box-1.13.18-windows-amd64.zip with -ZipPath. This source package already includes the embedded runtime, so this tool is only for refreshing/restoring it.'
}
$resolved = (Resolve-Path -LiteralPath $ZipPath).Path
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolved).Hash.ToLowerInvariant()
if ($hash -ne $ExpectedSha256) {
    throw "SHA256 mismatch. Expected $ExpectedSha256, got $hash"
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ('hongda-singbox-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null
try {
    Expand-Archive -LiteralPath $resolved -DestinationPath $temp -Force
    $core = Get-ChildItem -Path $temp -Recurse -Filter 'sing-box.exe' | Select-Object -First 1
    $cronet = Get-ChildItem -Path $temp -Recurse -Filter 'libcronet.dll' | Select-Object -First 1
    if (-not $core -or -not $cronet) { throw 'Archive does not contain sing-box.exe + libcronet.dll.' }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Copy-Item -LiteralPath $core.FullName -Destination (Join-Path $Destination 'sing-box.exe') -Force
    Copy-Item -LiteralPath $cronet.FullName -Destination (Join-Path $Destination 'libcronet.dll') -Force
    Write-Host "Embedded core refreshed: $Destination"
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
