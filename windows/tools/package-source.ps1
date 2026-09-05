param(
    [string]$Version = "1.6.8",
    [string]$OutputDirectory = ""
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Split-Path -Parent (Split-Path -Parent $Root)
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$Top = "Hongda-Starlink-V$Version-Windows-Source"
$OutZip = Join-Path $OutputDirectory "$Top.zip"
if (Test-Path -LiteralPath $OutZip) {
    Remove-Item -LiteralPath $OutZip -Force
}

$ExcludeDirs = @('build', '.dart_tool', 'dist', '.git')
$ExcludeRelative = @(
    'runtime\service\HongdaService.exe'
)

$Files = Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object {
    $Relative = $_.FullName.Substring($Root.Length + 1)
    $TopDir = $Relative.Split([IO.Path]::DirectorySeparatorChar)[0]
    if ($ExcludeDirs -contains $TopDir) { return $false }
    if ($ExcludeRelative -contains $Relative) { return $false }
    if ($Relative.Split([IO.Path]::DirectorySeparatorChar) -contains 'ephemeral') {
        return $false
    }
    if ($_.Name -like '_tmp_*') { return $false }
    return $true
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$Stream = [IO.File]::Open($OutZip, [IO.FileMode]::Create)
$Archive = New-Object IO.Compression.ZipArchive($Stream, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($File in $Files) {
        $Relative = $File.FullName.Substring($Root.Length + 1).Replace('\', '/')
        $EntryName = "$Top/$Relative"
        $Entry = $Archive.CreateEntry($EntryName, [IO.Compression.CompressionLevel]::Optimal)
        $EntryStream = $Entry.Open()
        $Input = [IO.File]::OpenRead($File.FullName)
        try {
            $Input.CopyTo($EntryStream)
        } finally {
            $Input.Dispose()
            $EntryStream.Dispose()
        }
    }
} finally {
    $Archive.Dispose()
    $Stream.Dispose()
}

Write-Host "Source package: $OutZip"
Write-Host "Entries: $($Files.Count)"
Write-Host "Size: $([math]::Round((Get-Item -LiteralPath $OutZip).Length / 1MB, 2)) MB"
