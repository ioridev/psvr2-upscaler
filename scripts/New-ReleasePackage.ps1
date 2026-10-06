#Requires -Version 5.1
<#
.SYNOPSIS
Builds a source-only end-user ZIP from an explicit release allowlist.
.DESCRIPTION
No driver DLLs, SDKs, external checkouts, build tools, local evidence or settings
are included. The resulting folder can be used without the repository checkout.
.EXAMPLE
.\scripts\New-ReleasePackage.ps1 -Version 0.1.0
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$')]
    [string]$Version = '0.1.0',
    [string]$SourceRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts\release'),
    [switch]$Force
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$SourceRoot = [IO.Path]::GetFullPath($SourceRoot)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$packageName = 'PSVR2-Upscaling-v' + $Version
$zipPath = Join-Path $OutputDirectory ($packageName + '.zip')
$checksumPath = $zipPath + '.sha256'

# Deliberately enumerate each file. Never archive the checkout or a folder glob.
$releaseFiles = @(
    'Start-PSVR2-Upscaling.cmd',
    'README.md',
    'README.en.md',
    'LICENSE',
    'THIRD_PARTY_NOTICES.md',
    'scripts/Show-Psvr2Upscaling.ps1',
    'scripts/Manage-Psvr2Upscaling.ps1',
    'scripts/Invoke-HostPsvr2Upscaling.ps1',
    'scripts/Invoke-HostPsvr2UpscalingWorker.ps1',
    'shaders/distort_ps_layered.hlsl',
    'shaders/psvr2_easu.hlsl',
    'licenses/CustomHeadsetOpenVR-GPL-2.0.txt',
    'licenses/FidelityFX-FSR-MIT.txt',
    'licenses/OpenVR-BSD-3-Clause.txt'
)
foreach ($relative in $releaseFiles) {
    $file = Join-Path $SourceRoot $relative
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing release file: $relative" }
    if ((Get-Item -LiteralPath $file).Length -eq 0) { throw "Empty release file: $relative" }
}
if (-not $Force -and ((Test-Path -LiteralPath $zipPath) -or (Test-Path -LiteralPath $checksumPath))) {
    throw "Release output already exists. Use -Force to rebuild: $zipPath"
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$temporary = Join-Path $OutputDirectory ('.package-' + [guid]::NewGuid().ToString('N') + '.tmp')
try {
    $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($relative in $releaseFiles) {
                $entry = $archive.CreateEntry($packageName + '/' + $relative, [IO.Compression.CompressionLevel]::Optimal)
                # Stable ZIP metadata makes repeated builds of the same source reproducible.
                $entry.LastWriteTime = [DateTimeOffset]::new(2020, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
                $entryStream = $entry.Open()
                try {
                    $bytes = [IO.File]::ReadAllBytes((Join-Path $SourceRoot $relative))
                    $entryStream.Write($bytes, 0, $bytes.Length)
                }
                finally { $entryStream.Dispose() }
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }
    if (Test-Path -LiteralPath $zipPath) { [IO.File]::Replace($temporary, $zipPath, [NullString]::Value) }
    else { [IO.File]::Move($temporary, $zipPath) }
}
finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
$sha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($checksumPath, ($sha256 + '  ' + [IO.Path]::GetFileName($zipPath) + "`n"), [Text.UTF8Encoding]::new($false))
[pscustomobject]@{
    zipPath = $zipPath
    checksumPath = $checksumPath
    sha256 = $sha256
    fileCount = $releaseFiles.Count
    packageName = $packageName
}
