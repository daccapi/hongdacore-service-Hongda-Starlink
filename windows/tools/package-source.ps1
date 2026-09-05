param(
    [string]$CoreSource = "",
    [string]$Output = ""
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Version = '1.6.22'
if ([string]::IsNullOrWhiteSpace($CoreSource)) {
    $Candidates = @(
        (Join-Path (Split-Path -Parent $Root) 'hongda-core'),
        (Join-Path (Split-Path -Parent (Split-Path -Parent $Root)) 'hongda-core'),
        (Join-Path $Root 'third_party\hongda-core')
    )
    $CoreSource = $Candidates | Where-Object {
        Test-Path -LiteralPath (Join-Path $_ 'go.mod') -PathType Leaf
    } | Select-Object -First 1
}
if ([string]::IsNullOrWhiteSpace($CoreSource)) {
    throw 'HongdaCore source was not found.'
}
$CoreSource = (Resolve-Path -LiteralPath $CoreSource).Path
if ([string]::IsNullOrWhiteSpace($Output)) {
    $Output = Join-Path (Split-Path -Parent $Root) "Hongda-Starlink-V$Version-Windows-Source.zip"
}
$Output = [System.IO.Path]::GetFullPath($Output)

$Stage = Join-Path $env:TEMP ("hongda-starlink-source-" + [guid]::NewGuid().ToString('N'))
$Destination = Join-Path $Stage "Hongda-Starlink-V$Version-Windows-Source"
New-Item -ItemType Directory -Force -Path $Destination | Out-Null

$ExcludedWindowsParts = @(
    '\build\', '\dist\', '\.dart_tool\', '\core\',
	'\third_party\sing-box\', '\windows\flutter\ephemeral\',
	'\service\embedded\', '\runtime\service\'
)
Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object {
    $path = $_.FullName
	-not ($ExcludedWindowsParts | Where-Object { $path.Contains($_) }) -and
    $_.Name -ne 'LICENSE-sing-box.txt'
} | ForEach-Object {
    $relative = $_.FullName.Substring($Root.Length).TrimStart('\', '/')
    $target = Join-Path $Destination $relative
    $targetDirectory = Split-Path -Parent $target
    New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
    Copy-Item -LiteralPath $_.FullName -Destination $target -Force
}

$CoreDestination = Join-Path $Destination 'third_party\hongda-core'
Get-ChildItem -LiteralPath $CoreSource -Recurse -File | Where-Object {
    -not $_.FullName.Contains('\dist\') -and
	-not $_.FullName.Contains('\build\') -and
	-not $_.FullName.Contains('\Hongda-Starlink-V1.6.8-Windows-Source\') -and
    $_.Name -ne 'HongdaCore.exe'
} | ForEach-Object {
    $relative = $_.FullName.Substring($CoreSource.Length).TrimStart('\', '/')
    $target = Join-Path $CoreDestination $relative
    $targetDirectory = Split-Path -Parent $target
    New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
    Copy-Item -LiteralPath $_.FullName -Destination $target -Force
}

$outputDirectory = Split-Path -Parent $Output
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
if (Test-Path -LiteralPath $Output) { Remove-Item -LiteralPath $Output -Force }
Compress-Archive -Path $Destination -DestinationPath $Output -CompressionLevel Optimal -Force

$resolvedTemp = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
$resolvedStage = [System.IO.Path]::GetFullPath($Stage)
if (-not $resolvedStage.StartsWith($resolvedTemp, [System.StringComparison]::OrdinalIgnoreCase) -or
    (Split-Path -Leaf $resolvedStage) -notlike 'hongda-starlink-source-*') {
    throw "Refusing to remove unexpected staging path: $resolvedStage"
}
Remove-Item -LiteralPath $resolvedStage -Recurse -Force

$file = Get-Item -LiteralPath $Output
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Output).Hash
Write-Host "Source package: $($file.FullName)"
Write-Host "Size: $([math]::Round($file.Length / 1MB, 2)) MB"
Write-Host "SHA256: $hash"
