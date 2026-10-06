#Requires -Version 5.1
<#
.SYNOPSIS
Installs, removes, or inspects the PSVR2 compositor EASU shader patch.
.DESCRIPTION
Close SteamVR and VRChat before Install/Configure/Uninstall. Status and -DryRun are read-only.
ResolutionScale is SteamVR's per-application pixel percentage, not an axis scale.
Original shaders and an exact property ledger are retained under BackupRoot.
Configuration alone does not prove runtime activation or image quality.
.EXAMPLE
.\scripts\Manage-Psvr2Upscaling.ps1 -Action Status
.EXAMPLE
.\scripts\Manage-Psvr2Upscaling.ps1 -Action Install -ResolutionScale 67 -DryRun
.EXAMPLE
.\scripts\Manage-Psvr2Upscaling.ps1 -Action Install -ResolutionScale 67
.EXAMPLE
.\scripts\Manage-Psvr2Upscaling.ps1 -Action Uninstall
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Install', 'Configure', 'Uninstall')][string]$Action = 'Status',
    [ValidateRange(20, 100)][int]$ResolutionScale = 67,
    [switch]$SkipResolutionScale,
    [switch]$DryRun,
    [string]$SourceRoot = '',
    [string]$OpenVrPaths = (Join-Path $env:LOCALAPPDATA 'openvr\openvrpaths.vrpath'),
    [string]$CustomHeadsetSettings = (Join-Path $env:APPDATA 'CustomHeadset\settings.json'),
    [string]$BackupRoot = (Join-Path $env:LOCALAPPDATA 'PSVR2Upscaling')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$baselineShaderSha256 = '65CAAA283BE3F4FD9B8F62459E2E73D5D3B5136E6448A635C518217003E902CB'
$shaderNames = @('distort_ps_layered.hlsl', 'psvr2_easu.hlsl')
$utf8 = New-Object System.Text.UTF8Encoding($false)
if ([string]::IsNullOrWhiteSpace($SourceRoot)) { $SourceRoot = Split-Path -Parent $PSScriptRoot }
if ($Action -eq 'Configure' -and $SkipResolutionScale) { throw 'Configure requires ResolutionScale; SkipResolutionScale is only an Install option.' }

function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required JSON file is missing: $Path" }
    $document = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    if ($null -eq $document -or $document -isnot [pscustomobject]) { throw "Expected a JSON object: $Path" }
    return $document
}

function Has-Property($Object, [string]$Name) {
    return $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function Set-Property($Object, [string]$Name, $Value) {
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Full-Path([string]$Path) { return [IO.Path]::GetFullPath($Path).TrimEnd('\', '/') }
function Sha256([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Same-Value($Left, $Right) {
    return ($Left | ConvertTo-Json -Compress -Depth 50) -ceq ($Right | ConvertTo-Json -Compress -Depth 50)
}

function Json-Bytes($Object) {
    return ,$utf8.GetBytes(($Object | ConvertTo-Json -Depth 50) + [Environment]::NewLine)
}

function Write-Atomic([string]$Path, [byte[]]$Bytes) {
    $temporary = Join-Path (Split-Path -Parent $Path) ('.psvr2-easu-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Get-RunningVrProcesses {
    return @(Get-Process -Name vrserver, vrcompositor, VRChat -ErrorAction SilentlyContinue |
        Select-Object ProcessName, Id)
}

function Assert-Stopped {
    $running = @(Get-RunningVrProcesses)
    if ($running.Count -gt 0) {
        throw ('Close SteamVR and VRChat before modifying the patch. Running: ' +
            (($running | ForEach-Object { $_.ProcessName + ' (PID ' + $_.Id + ')' }) -join ', '))
    }
}

function Test-WriteAccess([string]$Path) {
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw "Directory is missing: $directory" }
    if ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).IsReadOnly) { throw "File is read-only: $Path" }
    $probe = Join-Path $directory ('.psvr2-easu-access-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try { [IO.File]::WriteAllBytes($probe, [byte[]]@()) }
    finally { if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force } }
}

function Get-LedgerItem($Document, [string]$File, [string]$Section, [string]$Name, $Value) {
    $sectionExisted = Has-Property $Document $Section
    if ($sectionExisted -and $Document.$Section -isnot [pscustomobject]) { throw "Expected object for $Section in $File" }
    $propertyExisted = $sectionExisted -and (Has-Property $Document.$Section $Name)
    return [pscustomobject]@{
        file = $File; section = $Section; name = $Name; sectionExisted = $sectionExisted
        existed = $propertyExisted; original = $(if ($propertyExisted) { $Document.$Section.$Name } else { $null })
        installed = $Value
    }
}

function Apply-Ledger($Documents, $Ledger, [bool]$Restore) {
    foreach ($entry in $Ledger) {
        $document = $Documents[$entry.file]
        $sectionExists = Has-Property $document $entry.section
        if ($sectionExists -and $document.($entry.section) -isnot [pscustomobject]) {
            throw "Expected an object for $($entry.section) in $($entry.file)"
        }
        if (-not $sectionExists) { Set-Property $document $entry.section ([pscustomobject]@{}) }
        $section = $document.($entry.section)
        if ($Restore) {
            if ($entry.existed) { Set-Property $section $entry.name $entry.original }
            else { $section.PSObject.Properties.Remove($entry.name) }
        }
        else { Set-Property $section $entry.name $entry.installed }
    }
    if ($Restore) {
        foreach ($entry in $Ledger) {
            $document = $Documents[$entry.file]
            if (-not $entry.sectionExisted -and (Has-Property $document $entry.section) -and
                @($document.($entry.section).PSObject.Properties).Count -eq 0) {
                $document.PSObject.Properties.Remove($entry.section)
            }
        }
    }
}

$OpenVrPaths = Full-Path $OpenVrPaths
$CustomHeadsetSettings = Full-Path $CustomHeadsetSettings
$BackupRoot = Full-Path $BackupRoot
$SourceRoot = Full-Path $SourceRoot
$paths = Read-Json $OpenVrPaths
if (-not (Has-Property $paths 'runtime') -or @($paths.runtime).Count -ne 1) { throw 'Expected exactly one active OpenVR runtime.' }
if (-not (Has-Property $paths 'config') -or @($paths.config).Count -lt 1) { throw 'OpenVR configuration path is missing.' }
$runtimeRoot = Full-Path @($paths.runtime)[0]
$steamSettings = Join-Path (Full-Path @($paths.config)[0]) 'steamvr.vrsettings'
$driverRoot = Join-Path $runtimeRoot 'drivers\CustomHeadsetOpenVR'
$shaderRoot = Join-Path $driverRoot 'resources\shaders\d3d11'
$driverManifest = Read-Json (Join-Path $driverRoot 'driver.vrdrivermanifest')
$manifestPath = Join-Path $BackupRoot 'current.json'
$loadedManifestBytes = if (Test-Path -LiteralPath $manifestPath) { [IO.File]::ReadAllBytes($manifestPath) } else { $null }
$manifest = if ($null -ne $loadedManifestBytes) { $utf8.GetString($loadedManifestBytes).TrimStart([char]0xFEFF) | ConvertFrom-Json } else { $null }
$configPaths = @{ customHeadset = $CustomHeadsetSettings; steamVr = $steamSettings }
$loadedConfigBytes = @{}
$documents = @{}
foreach ($key in $configPaths.Keys) {
    # Parse exactly the bytes retained for optimistic concurrency checks below.
    $loadedConfigBytes[$key] = [IO.File]::ReadAllBytes($configPaths[$key])
    $documents[$key] = $utf8.GetString($loadedConfigBytes[$key]).TrimStart([char]0xFEFF) | ConvertFrom-Json
    if ($null -eq $documents[$key] -or $documents[$key] -isnot [pscustomobject]) { throw "Expected a JSON object: $($configPaths[$key])" }
}

if ($null -ne $manifest) {
    if ($manifest.schemaVersion -ne 1 -or $manifest.driverRoot -ine $driverRoot -or
        $manifest.customHeadsetSettings -ine $CustomHeadsetSettings -or $manifest.steamSettings -ine $steamSettings) {
        throw 'Backup manifest does not match this runtime/configuration. Refusing to modify another installation.'
    }
    $generationRoot = Full-Path $manifest.backupDirectory
    if (-not $generationRoot.StartsWith($BackupRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Backup generation is outside BackupRoot.'
    }
    if (@($manifest.files).Count -ne $shaderNames.Count -or
        @($manifest.files | Where-Object { $_.name -notin $shaderNames }).Count -gt 0 -or
        @($manifest.files.name | Select-Object -Unique).Count -ne $shaderNames.Count) {
        throw 'Backup manifest has an unrecognized shader file list.'
    }
    foreach ($entry in $manifest.properties) {
        $allowed = ($entry.file -eq 'customHeadset' -and $entry.section -eq 'customShader' -and
            $entry.name -in @('enable', 'enableForOther', 'samplingFilter', 'enableFilterForOverlay', 'enableFilterForDashboard')) -or
            ($entry.file -eq 'steamVr' -and $entry.section -eq 'steam.app.438100' -and $entry.name -eq 'resolutionScale')
        if (-not $allowed) { throw 'Backup manifest contains an unrecognized configuration property.' }
    }
    $propertyIds = @($manifest.properties | ForEach-Object { $_.file + '/' + $_.section + '/' + $_.name })
    if (@($propertyIds | Select-Object -Unique).Count -ne $propertyIds.Count -or
        @($manifest.properties | Where-Object { $_.file -eq 'customHeadset' }).Count -ne 5) {
        throw 'Backup manifest has duplicate or missing managed properties.'
    }
}

# Configure uses a write-ahead journal inside current.json. Its Installed ledger
# remains unchanged until the settings write has been verified. A later Configure
# with the same requested value, or Uninstall, can recover either atomic outcome.
$pendingConfiguration = if (Has-Property $manifest 'pendingConfigure') { $manifest.pendingConfigure } else { $null }
if ($null -ne $pendingConfiguration) {
    $next = $pendingConfiguration.entry
    if ($manifest.state -ne 'Installed' -or $next.file -ne 'steamVr' -or $next.section -ne 'steam.app.438100' -or
        $next.name -ne 'resolutionScale' -or $next.installed -isnot [ValueType] -or
        $next.installed -lt 20 -or $next.installed -gt 100 -or [int]$next.installed -ne $next.installed) {
        throw 'Invalid pending Configure journal.'
    }
    $previousScale = @($manifest.properties | Where-Object { $_.file -eq 'steamVr' })
    if ($previousScale.Count -eq 1) {
        $previous = $previousScale[0]
        if (-not $pendingConfiguration.beforeExisted -or -not (Same-Value $pendingConfiguration.beforeValue $previous.installed) -or
            $next.existed -ne $previous.existed -or $next.sectionExisted -ne $previous.sectionExisted -or
            -not (Same-Value $next.original $previous.original)) { throw 'Pending Configure journal does not match the original ledger.' }
    }
    elseif ($next.existed -ne $pendingConfiguration.beforeExisted -or
        $next.sectionExisted -ne $pendingConfiguration.beforeSectionExisted -or
        -not (Same-Value $next.original $pendingConfiguration.beforeValue)) { throw 'Pending Configure journal has inconsistent original values.' }
}

if ($Action -eq 'Status') {
    $shaderStatus = foreach ($name in $shaderNames) {
        $destination = Join-Path $shaderRoot $name
        $hash = if (Test-Path -LiteralPath $destination) { Sha256 $destination } else { $null }
        $record = if ($null -ne $manifest) { @($manifest.files | Where-Object name -eq $name)[0] } else { $null }
        [pscustomobject]@{ name = $name; sha256 = $hash; matchesRecordedPatch = ($null -ne $record -and $hash -eq $record.installedSha256) }
    }
    $application = if (Has-Property $documents.steamVr 'steam.app.438100') { $documents.steamVr.'steam.app.438100' } else { $null }
    [pscustomobject]@{
        action = 'Status'; driverVersion = $driverManifest.version; driverRoot = $driverRoot
        backupManifest = $(if ($null -ne $manifest) { $manifestPath } else { $null })
        recordedState = $(if ($null -ne $manifest) { $manifest.state } else { 'NotManaged' })
        pendingConfiguration = $pendingConfiguration
        shaders = @($shaderStatus)
        customShader = $(if (Has-Property $documents.customHeadset 'customShader') { $documents.customHeadset.customShader } else { $null })
        vrchatResolutionScale = $(if (Has-Property $application 'resolutionScale') { $application.resolutionScale } else { $null })
        runningProcesses = @(Get-RunningVrProcesses)
        runtimeActivation = 'Unverified: inspect compositor replacement/compilation and live PSVR2 output separately.'
    } | ConvertTo-Json -Depth 50
    return
}

if (-not $DryRun) { Assert-Stopped }
if ($driverManifest.name -ne 'CustomHeadsetOpenVR' -or $driverManifest.version -ne '1.3.0') {
    throw 'Only the inspected CustomHeadsetOpenVR 1.3.0 baseline is supported. Reassess before patching another version.'
}

$managed = $null -ne $manifest -and $manifest.state -in @('Prepared', 'Installed')
if ($null -ne $manifest -and $manifest.state -notin @('Prepared', 'Installed', 'Uninstalled')) {
    throw "Unknown backup state: $($manifest.state)"
}
if ($Action -eq 'Uninstall' -and -not $managed) {
    [pscustomobject]@{ action = $Action; changed = $false; detail = 'No active managed installation.' } | ConvertTo-Json
    return
}
if ($Action -eq 'Configure' -and ($null -eq $manifest -or $manifest.state -ne 'Installed')) {
    throw 'Configure requires an Installed generation. Finish or uninstall a Prepared installation first.'
}
if ($null -ne $pendingConfiguration -and $Action -eq 'Install') {
    throw 'A Configure transaction is pending. Repeat Configure with its recorded resolution, or Uninstall, before Install.'
}
if ($null -ne $pendingConfiguration -and $Action -eq 'Configure' -and $ResolutionScale -ne $pendingConfiguration.entry.installed) {
    throw "A Configure transaction is pending. Repeat Configure -ResolutionScale $($pendingConfiguration.entry.installed), or Uninstall, to recover it."
}

$newManifest = $false
if ($Action -eq 'Install' -and -not $managed) {
    $originalShader = Join-Path $shaderRoot 'distort_ps_layered.hlsl'
    if (-not (Test-Path -LiteralPath $originalShader) -or (Sha256 $originalShader) -ne $baselineShaderSha256) {
        throw 'Installed distortion shader does not match the inspected baseline. Refusing to overwrite unknown modifications.'
    }
    if (Test-Path -LiteralPath (Join-Path $shaderRoot 'psvr2_easu.hlsl')) {
        throw 'An unmanaged psvr2_easu.hlsl already exists. Refusing to overwrite it.'
    }
    $ledger = @(
        Get-LedgerItem $documents.customHeadset 'customHeadset' 'customShader' 'enable' $true
        Get-LedgerItem $documents.customHeadset 'customHeadset' 'customShader' 'enableForOther' $true
        Get-LedgerItem $documents.customHeadset 'customHeadset' 'customShader' 'samplingFilter' 'FSR_EASU'
        Get-LedgerItem $documents.customHeadset 'customHeadset' 'customShader' 'enableFilterForOverlay' $false
        Get-LedgerItem $documents.customHeadset 'customHeadset' 'customShader' 'enableFilterForDashboard' $false
    )
    if (-not $SkipResolutionScale) {
        $ledger += Get-LedgerItem $documents.steamVr 'steamVr' 'steam.app.438100' 'resolutionScale' $ResolutionScale
    }
    $generationRoot = Join-Path $BackupRoot ('generations\' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N'))
    $files = foreach ($name in $shaderNames) {
        $source = Join-Path $SourceRoot ('shaders\' + $name)
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Patch source is missing: $source" }
        $destination = Join-Path $shaderRoot $name
        $exists = Test-Path -LiteralPath $destination -PathType Leaf
        [pscustomobject]@{
            name = $name; existed = $exists
            originalSha256 = $(if ($exists) { Sha256 $destination } else { $null })
            installedSha256 = (Sha256 $source)
        }
    }
    $manifest = [pscustomobject]@{
        schemaVersion = 1; state = 'Prepared'; createdUtc = [DateTime]::UtcNow.ToString('o')
        driverRoot = $driverRoot; driverVersion = $driverManifest.version
        customHeadsetSettings = $CustomHeadsetSettings; steamSettings = $steamSettings
        backupDirectory = $generationRoot; baselineShaderSha256 = $baselineShaderSha256
        files = @($files); properties = @($ledger)
    }
    $newManifest = $true
}

# Every shader must still be either the recorded patch or (during crash recovery)
# its recorded original. Never silently overwrite third-party shader edits.
foreach ($file in $manifest.files) {
    $destination = Join-Path $shaderRoot $file.name
    $exists = Test-Path -LiteralPath $destination -PathType Leaf
    $currentHash = if ($exists) { Sha256 $destination } else { $null }
    $matchesPatch = $exists -and $currentHash -eq $file.installedSha256
    $matchesOriginal = ($file.existed -and $exists -and $currentHash -eq $file.originalSha256) -or (-not $file.existed -and -not $exists)
    if (-not $matchesPatch -and -not ($manifest.state -eq 'Prepared' -and $matchesOriginal)) {
        throw "Shader differs from the recorded patch generation: $destination"
    }
    if ($Action -eq 'Install') {
        $source = Join-Path $SourceRoot ('shaders\' + $file.name)
        if (-not (Test-Path -LiteralPath $source) -or (Sha256 $source) -ne $file.installedSha256) {
            throw 'Source shaders differ from the installed generation. Uninstall the current generation before installing an update.'
        }
    }
    if (-not $newManifest -and $file.existed) {
        $original = Join-Path $generationRoot $file.name
        if (-not (Test-Path -LiteralPath $original) -or (Sha256 $original) -ne $file.originalSha256) {
            throw "Original shader backup is missing or damaged: $original"
        }
    }
}

if ($Action -eq 'Install' -and -not $newManifest) {
    $scaleRecords = @($manifest.properties | Where-Object { $_.file -eq 'steamVr' })
    if (($SkipResolutionScale -and $scaleRecords.Count -gt 0) -or
        (-not $SkipResolutionScale -and ($scaleRecords.Count -ne 1 -or $scaleRecords[0].installed -ne $ResolutionScale))) {
        throw 'Resolution options differ from the installed generation. Use Configure to change resolution, or Uninstall before changing the deployment profile.'
    }
}

# A later user edit to a managed property is a conflict; unrelated properties are
# always reread and retained. Prepared state also accepts the original value.
foreach ($entry in $manifest.properties) {
    if ($null -ne $pendingConfiguration -and $entry.file -eq 'steamVr') { continue }
    $document = $documents[$entry.file]
    $sectionExists = Has-Property $document $entry.section
    if ($sectionExists -and $document.($entry.section) -isnot [pscustomobject]) { throw "Expected an object for $($entry.section)" }
    $exists = $sectionExists -and (Has-Property $document.($entry.section) $entry.name)
    $value = if ($exists) { $document.($entry.section).($entry.name) } else { $null }
    $matchesPatch = $exists -and (Same-Value $value $entry.installed)
    $matchesOriginal = ($entry.existed -and $exists -and (Same-Value $value $entry.original)) -or (-not $entry.existed -and -not $exists)
    if (-not $matchesPatch -and -not ($manifest.state -eq 'Prepared' -and $matchesOriginal)) {
        throw "Managed setting changed since installation: $($entry.section).$($entry.name). Resolve this conflict before proceeding."
    }
}
if ($null -ne $pendingConfiguration) {
    $sectionExists = Has-Property $documents.steamVr 'steam.app.438100'
    if ($sectionExists -and $documents.steamVr.'steam.app.438100' -isnot [pscustomobject]) { throw 'Expected an object for steam.app.438100' }
    $exists = $sectionExists -and (Has-Property $documents.steamVr.'steam.app.438100' 'resolutionScale')
    $value = if ($exists) { $documents.steamVr.'steam.app.438100'.resolutionScale } else { $null }
    $matchesBefore = ($exists -eq $pendingConfiguration.beforeExisted) -and (Same-Value $value $pendingConfiguration.beforeValue)
    $matchesAfter = $exists -and (Same-Value $value $pendingConfiguration.entry.installed)
    if (-not $matchesBefore -and -not $matchesAfter) { throw 'Managed resolution changed outside the pending Configure transaction.' }
    if ($Action -eq 'Uninstall') {
        $manifest.properties = @($manifest.properties | Where-Object { $_.file -ne 'steamVr' }) + @($pendingConfiguration.entry)
        $manifest.PSObject.Properties.Remove('pendingConfigure')
    }
}

$report = [pscustomobject]@{
    action = $Action; dryRun = [bool]$DryRun; driverRoot = $driverRoot; backupManifest = $manifestPath
    shaders = $manifest.files; properties = $manifest.properties
    runningProcesses = @(Get-RunningVrProcesses)
    runtimeActivation = 'Unverified: successful deployment is not proof of runtime activation.'
}
if ($Action -eq 'Configure') {
    $scaleRecords = @($manifest.properties | Where-Object { $_.file -eq 'steamVr' })
    $nextEntry = if ($null -ne $pendingConfiguration) { $pendingConfiguration.entry }
        elseif ($scaleRecords.Count -eq 1) { $scaleRecords[0] | ConvertTo-Json -Depth 50 | ConvertFrom-Json }
        else { Get-LedgerItem $documents.steamVr 'steamVr' 'steam.app.438100' 'resolutionScale' $ResolutionScale }
    $nextEntry.installed = $ResolutionScale
    $nextProperties = @($manifest.properties | Where-Object { $_.file -ne 'steamVr' }) + @($nextEntry)
    $report.properties = $nextProperties
    Set-Property $report 'state' 'Installed'
    $changeNeeded = $null -ne $pendingConfiguration -or $scaleRecords.Count -eq 0 -or -not (Same-Value $scaleRecords[0].installed $ResolutionScale)
    Set-Property $report 'changed' ([bool]$changeNeeded)
    if ($DryRun -or -not $changeNeeded) { $report | ConvertTo-Json -Depth 50; return }

    # No shader/custom-headset writes in Configure. Keep the original generation
    # and immutable original-manifest.json, even when management starts after Skip.
    Test-WriteAccess $steamSettings
    Test-WriteAccess $manifestPath
    $originalSteamBytes = $loadedConfigBytes.steamVr
    $nextManifest = $manifest | ConvertTo-Json -Depth 50 | ConvertFrom-Json
    $nextManifest.properties = $nextProperties
    $nextManifest.PSObject.Properties.Remove('pendingConfigure')
    Set-Property $nextManifest 'updatedUtc' ([DateTime]::UtcNow.ToString('o'))
    $journalManifest = $manifest | ConvertTo-Json -Depth 50 | ConvertFrom-Json
    if ($null -eq $pendingConfiguration) {
        $before = Get-LedgerItem $documents.steamVr 'steamVr' 'steam.app.438100' 'resolutionScale' $ResolutionScale
        Set-Property $journalManifest 'pendingConfigure' ([pscustomobject]@{
            beforeSectionExisted = $before.sectionExisted; beforeExisted = $before.existed; beforeValue = $before.original
            entry = $nextEntry; preparedUtc = [DateTime]::UtcNow.ToString('o')
        })
    }
    Apply-Ledger $documents @($nextEntry) $false
    $nextSteamBytes = Json-Bytes $documents.steamVr
    Assert-Stopped
    foreach ($key in $configPaths.Keys) {
        if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configPaths[$key])) -cne [Convert]::ToBase64String($loadedConfigBytes[$key])) {
            throw "Configuration changed during preflight: $($configPaths[$key]). Retry after closing the settings editor."
        }
    }
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($manifestPath)) -cne [Convert]::ToBase64String($loadedManifestBytes)) {
        throw 'Backup manifest changed during Configure preflight.'
    }
    foreach ($file in $manifest.files) {
        if ((Sha256 (Join-Path $shaderRoot $file.name)) -ne $file.installedSha256) { throw 'Shader changed during Configure preflight.' }
    }
    $journalWritten = $false
    $settingsAttempted = $false
    try {
        Write-Atomic $manifestPath (Json-Bytes $journalManifest)
        $journalWritten = $true
        $settingsAttempted = $true
        Write-Atomic $steamSettings $nextSteamBytes
        if (-not (Same-Value (Read-Json $steamSettings) $documents.steamVr)) { throw 'Configure JSON readback failed.' }
        Write-Atomic $manifestPath (Json-Bytes $nextManifest)
        if (-not (Same-Value (Read-Json $manifestPath) $nextManifest)) { throw 'Configure manifest readback failed.' }
    }
    catch {
        $failure = $_
        $rollbackFailures = @()
        if ($journalWritten) {
            if ($settingsAttempted) {
                try {
                    # An OS sharing violation can leave the original file intact.
                    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($steamSettings)) -cne [Convert]::ToBase64String($originalSteamBytes)) {
                        Write-Atomic $steamSettings $originalSteamBytes
                    }
                }
                catch { $rollbackFailures += "Settings rollback: $_" }
            }
            if ($rollbackFailures.Count -eq 0) {
                try { Write-Atomic $manifestPath $loadedManifestBytes }
                catch { $rollbackFailures += "Manifest rollback: $_" }
            }
            else {
                # Preserve recovery metadata if either atomic settings outcome remains.
                try { Write-Atomic $manifestPath (Json-Bytes $journalManifest) }
                catch { $rollbackFailures += "Recovery journal: $_" }
            }
        }
        if ($rollbackFailures.Count) { throw "Configure failed: $failure. Recovery may be needed: $($rollbackFailures -join '; ')" }
        throw "Configure failed; changed files were rolled back: $failure"
    }
    $report | ConvertTo-Json -Depth 50
    return
}
if ($DryRun) { $report | ConvertTo-Json -Depth 50; return }

$affectedConfigKeys = @($manifest.properties.file | Select-Object -Unique)
$targetPaths = @($manifest.files | ForEach-Object { Join-Path $shaderRoot $_.name }) +
    @($affectedConfigKeys | ForEach-Object { $configPaths[$_] })
foreach ($target in $targetPaths) { Test-WriteAccess $target }
$snapshots = @{}
foreach ($target in $targetPaths) {
    $snapshots[$target] = if (Test-Path -LiteralPath $target) { [IO.File]::ReadAllBytes($target) } else { $null }
}
foreach ($key in $affectedConfigKeys) {
    if ([Convert]::ToBase64String($loadedConfigBytes[$key]) -cne [Convert]::ToBase64String($snapshots[$configPaths[$key]])) {
        throw "Configuration changed during preflight: $($configPaths[$key]). Retry after closing the settings editor."
    }
}
if ($newManifest) {
    New-Item -ItemType Directory -Path $generationRoot -Force | Out-Null
    foreach ($file in $manifest.files) {
        if ($file.existed) {
            $backup = Join-Path $generationRoot $file.name
            # New generation directory: never replace an existing original.
            $stream = [IO.File]::Open($backup, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
            try { $bytes = $snapshots[(Join-Path $shaderRoot $file.name)]; $stream.Write($bytes, 0, $bytes.Length) }
            finally { $stream.Dispose() }
            if ((Sha256 $backup) -ne $file.originalSha256) { throw "Backup verification failed: $backup" }
        }
    }
    Write-Atomic (Join-Path $generationRoot 'original-manifest.json') (Json-Bytes $manifest)
    Write-Atomic $manifestPath (Json-Bytes $manifest)
}

Apply-Ledger $documents $manifest.properties ($Action -eq 'Uninstall')
$writes = @{}
foreach ($file in $manifest.files) {
    $target = Join-Path $shaderRoot $file.name
    if ($Action -eq 'Install') { $writes[$target] = [IO.File]::ReadAllBytes((Join-Path $SourceRoot ('shaders\' + $file.name))) }
    elseif ($file.existed) { $writes[$target] = [IO.File]::ReadAllBytes((Join-Path $generationRoot $file.name)) }
    else { $writes[$target] = $null }
}
foreach ($key in $affectedConfigKeys) { $writes[$configPaths[$key]] = Json-Bytes $documents[$key] }

Assert-Stopped
foreach ($target in $targetPaths) {
    $now = if (Test-Path -LiteralPath $target) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($target)) } else { $null }
    $before = if ($null -ne $snapshots[$target]) { [Convert]::ToBase64String($snapshots[$target]) } else { $null }
    if ($now -cne $before) { throw "File changed during preparation: $target" }
}

$committed = New-Object 'System.Collections.Generic.List[string]'
try {
    foreach ($target in $targetPaths) {
        if ($null -eq $writes[$target]) {
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
        }
        else { Write-Atomic $target $writes[$target] }
        $committed.Add($target)
    }
    foreach ($file in $manifest.files) {
        $target = Join-Path $shaderRoot $file.name
        $expected = if ($Action -eq 'Install') { $file.installedSha256 } else { $file.originalSha256 }
        if ($null -eq $expected) {
            if (Test-Path -LiteralPath $target) { throw "Expected shader removal failed: $target" }
        }
        elseif ((Sha256 $target) -ne $expected) { throw "Shader SHA256 readback failed: $target" }
    }
    foreach ($key in $affectedConfigKeys) {
        $readback = Read-Json $configPaths[$key]
        if (-not (Same-Value $readback $documents[$key])) { throw "JSON readback failed: $($configPaths[$key])" }
        $bytes = [IO.File]::ReadAllBytes($configPaths[$key])
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) { throw 'Unexpected UTF-8 BOM.' }
    }
    $manifest.state = if ($Action -eq 'Install') { 'Installed' } else { 'Uninstalled' }
    Set-Property $manifest 'updatedUtc' ([DateTime]::UtcNow.ToString('o'))
    Write-Atomic $manifestPath (Json-Bytes $manifest)
}
catch {
    $failure = $_
    $rollbackFailures = @()
    for ($index = $committed.Count - 1; $index -ge 0; $index--) {
        $target = $committed[$index]
        try {
            if ($null -eq $snapshots[$target]) { if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force } }
            else { Write-Atomic $target $snapshots[$target] }
        }
        catch { $rollbackFailures += "$target : $_" }
    }
    if ($rollbackFailures.Count -gt 0) { throw "Deployment failed: $failure. Rollback also failed: $($rollbackFailures -join '; '). Backups: $generationRoot" }
    throw "Deployment failed; changed files were rolled back: $failure"
}

Set-Property $report 'state' $manifest.state
Set-Property $report 'changed' $true
$report | ConvertTo-Json -Depth 50
