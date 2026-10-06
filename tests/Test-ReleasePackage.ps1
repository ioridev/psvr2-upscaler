#Requires -Version 5.1
<# Verifies that the distributable is complete and contains no local artifacts. #>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PackagePath,
    [string]$SourceRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$ExtractionDirectory = (Join-Path $env:TEMP ('psvr2-package-test-' + [guid]::NewGuid().ToString('N')))
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$PackagePath = [IO.Path]::GetFullPath($PackagePath)
$SourceRoot = [IO.Path]::GetFullPath($SourceRoot)
$ExtractionDirectory = [IO.Path]::GetFullPath($ExtractionDirectory)
if (Test-Path -LiteralPath $ExtractionDirectory) { throw 'Use a new extraction directory.' }
$expected = @(
    'Start-PSVR2-Upscaling.cmd', 'README.md', 'README.en.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md',
    'scripts/Show-Psvr2Upscaling.ps1', 'scripts/Manage-Psvr2Upscaling.ps1',
    'scripts/Invoke-HostPsvr2Upscaling.ps1', 'scripts/Invoke-HostPsvr2UpscalingWorker.ps1',
    'shaders/distort_ps_layered.hlsl', 'shaders/psvr2_easu.hlsl',
    'licenses/CustomHeadsetOpenVR-GPL-2.0.txt', 'licenses/FidelityFX-FSR-MIT.txt', 'licenses/OpenVR-BSD-3-Clause.txt'
)
$archive = [IO.Compression.ZipFile]::OpenRead($PackagePath)
try {
    if ($archive.Entries.Count -ne $expected.Count) { throw "Unexpected package entry count: $($archive.Entries.Count)" }
    $prefix = [IO.Path]::GetFileNameWithoutExtension($PackagePath) + '/'
    $actual = @()
    foreach ($entry in $archive.Entries) {
        if (-not $entry.FullName.StartsWith($prefix, [StringComparison]::Ordinal)) { throw "Unexpected package root: $($entry.FullName)" }
        $relative = $entry.FullName.Substring($prefix.Length)
        if ($relative -cnotin $expected) { throw "Unapproved file in package: $relative" }
        if ($relative -cin $actual) { throw "Duplicate package entry: $relative" }
        $actual += $relative
        $stream = $entry.Open()
        $memory = New-Object IO.MemoryStream
        try { $stream.CopyTo($memory); $bytes = $memory.ToArray() }
        finally { $stream.Dispose(); $memory.Dispose() }
        $hasher = [Security.Cryptography.SHA256]::Create()
        try { $zipHash = ([BitConverter]::ToString($hasher.ComputeHash($bytes))).Replace('-', '') }
        finally { $hasher.Dispose() }
        $sourceHash = (Get-FileHash -LiteralPath (Join-Path $SourceRoot $relative) -Algorithm SHA256).Hash
        if ($zipHash -ne $sourceHash) { throw "Package content differs from source: $relative" }
        $text = [Text.Encoding]::UTF8.GetString($bytes)
        if ($text -match '(?i)[A-Z]:[\\/]Users[\\/][^<>\s"'']+[\\/]' -or
            $text -match '(?i)(?:api[_-]?key|access[_-]?token|password)\s*=\s*["''][A-Za-z0-9_+/-]{24,}["'']') {
            throw "Possible local identity or embedded credential in release file: $relative"
        }
    }
}
finally { $archive.Dispose() }
$checksumText = [IO.File]::ReadAllText($PackagePath + '.sha256').Trim()
$checksum = (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($checksumText -cne ($checksum + '  ' + [IO.Path]::GetFileName($PackagePath))) { throw 'ZIP checksum sidecar does not match.' }

# Safe to extract only after every entry matches the exact relative allowlist.
[IO.Compression.ZipFile]::ExtractToDirectory($PackagePath, $ExtractionDirectory)
$extractedRoot = Join-Path $ExtractionDirectory ([IO.Path]::GetFileNameWithoutExtension($PackagePath))
foreach ($script in @(Get-ChildItem -LiteralPath (Join-Path $extractedRoot 'scripts') -Filter '*.ps1')) {
    $tokens = $null; $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw "Packaged script parse errors in $($script.Name): $($parseErrors -join '; ')" }
}
[pscustomobject]@{
    result = 'PASS'
    fileCount = $expected.Count
    sha256 = $checksum
    extractedRoot = $extractedRoot
    checks = 'Exact file allowlist, source byte hashes, no machine-local identity or embedded credential, ZIP SHA256, extracted PowerShell parsing.'
}
