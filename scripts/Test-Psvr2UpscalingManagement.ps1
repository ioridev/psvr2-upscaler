#Requires -Version 5.1
<# Exercises real deployment/rollback behavior against an isolated fake runtime.
   Does not change the installed SteamVR runtime or user configuration. #>
[CmdletBinding()]
param(
    [string]$FixtureRoot = (Join-Path $env:TEMP ('psvr2-easu-test-' + [guid]::NewGuid().ToString('N'))),
    [string]$ManagerPath = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
if ([string]::IsNullOrWhiteSpace($ManagerPath)) { $ManagerPath = Join-Path $PSScriptRoot 'Manage-Psvr2Upscaling.ps1' }
$manager = [IO.Path]::GetFullPath($ManagerPath)
$project = Split-Path -Parent $PSScriptRoot
$baseline = Join-Path $project 'research\CustomHeadsetOpenVR\CustomHeadsetOpenVR\DriverFiles\resources\shaders\d3d11\distort_ps_layered.hlsl'
if (-not (Test-Path -LiteralPath $baseline)) { throw "Inspected original shader is required: $baseline" }
if (Test-Path -LiteralPath $FixtureRoot) { throw 'Use a fresh fixture directory.' }
$FixtureRoot = [IO.Path]::GetFullPath($FixtureRoot)
$runtime = Join-Path $FixtureRoot 'runtime'
$driver = Join-Path $runtime 'drivers\CustomHeadsetOpenVR'
$shaders = Join-Path $driver 'resources\shaders\d3d11'
$source = Join-Path $FixtureRoot 'source'
$config = Join-Path $FixtureRoot 'config'
$settings = Join-Path $config 'settings.json'
$steam = Join-Path $config 'steamvr.vrsettings'
$vrpaths = Join-Path $FixtureRoot 'openvrpaths.vrpath'
$backup = Join-Path $FixtureRoot 'backups'
foreach ($directory in @($shaders, (Join-Path $source 'shaders'), $config)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
# Only this fixture script's child scope sees synthetic processes. The production
# guard is unchanged and is tested explicitly below. Every manager invocation is
# pinned to the newly created fixture paths, so a live user's VR session is safe.
$fixtureProcesses = @()
function Get-Process { [CmdletBinding()] param([string[]]$Name) return @($fixtureProcesses) }
function Write-Json([string]$Path, $Value) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 50), $utf8) }
function Read-Json([string]$Path) { return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json) }
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Has($Object, [string]$Name) { return $null -ne $Object.PSObject.Properties[$Name] }
function Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Run([string]$Action, [switch]$DryRun, [int]$ResolutionScale = 67, [switch]$SkipResolutionScale) {
    return (& $manager -Action $Action -DryRun:$DryRun -ResolutionScale $ResolutionScale -SkipResolutionScale:$SkipResolutionScale -SourceRoot $source -OpenVrPaths $vrpaths -CustomHeadsetSettings $settings -BackupRoot $backup | ConvertFrom-Json)
}
function Assert-Rejected([scriptblock]$Operation, [string]$Pattern) {
    $caught = $null
    try { & $Operation | Out-Null } catch { $caught = $_.ToString() }
    Assert ($null -ne $caught -and $caught -match $Pattern) "Expected rejection matching '$Pattern'; actual: $caught"
}

Copy-Item -LiteralPath $baseline -Destination (Join-Path $shaders 'distort_ps_layered.hlsl')
[IO.File]::WriteAllText((Join-Path $source 'shaders\distort_ps_layered.hlsl'), ([IO.File]::ReadAllText($baseline) + "`n// isolated test patch`n"), $utf8)
[IO.File]::WriteAllText((Join-Path $source 'shaders\psvr2_easu.hlsl'), "// isolated test include`n", $utf8)
Write-Json (Join-Path $driver 'driver.vrdrivermanifest') @{ name = 'CustomHeadsetOpenVR'; version = '1.3.0' }
Write-Json $vrpaths @{ runtime = @($runtime); config = @($config) }
Write-Json $settings @{ customShader = @{ enable = $true; enableForOther = $null; samplingFilter = 'FXAA2CAS'; colorMultiplier = @{ red = 0.8 } }; preservedText = 'PSVR2 fixture' }
Write-Json $steam @{ 'steam.app.438100' = @{ fovScale = 100 }; steamvr = @{ resolutionScale = 150; preferredRefreshRate = 120 } }
$initialSettings = Hash $settings
$initialSteam = Hash $steam
$initialShader = Hash (Join-Path $shaders 'distort_ps_layered.hlsl')
Assert-Rejected { Run Configure -DryRun } 'requires an Installed generation'

$null = Run Install -DryRun
Assert (-not (Test-Path -LiteralPath $backup)) 'Dry run created a backup directory.'
Assert ((Hash $settings) -eq $initialSettings -and (Hash $steam) -eq $initialSteam) 'Dry run modified configuration.'
Assert ((Hash (Join-Path $shaders 'distort_ps_layered.hlsl')) -eq $initialShader) 'Dry run modified a shader.'
# Force a real OS sharing violation after both shader writes, then verify rollback
# and recovery using the persisted Prepared manifest.
$lockedConfig = [IO.File]::Open($settings, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try { Assert-Rejected { Run Install } 'changed files were rolled back' }
finally { $lockedConfig.Dispose() }
Assert ((Hash (Join-Path $shaders 'distort_ps_layered.hlsl')) -eq $initialShader) 'Failed deployment did not roll back the original shader.'
Assert (-not (Test-Path -LiteralPath (Join-Path $shaders 'psvr2_easu.hlsl'))) 'Failed deployment did not remove the new include.'
Assert ((Hash $settings) -eq $initialSettings -and (Hash $steam) -eq $initialSteam) 'Failed deployment changed config.'
Assert ((Read-Json (Join-Path $backup 'current.json')).state -eq 'Prepared') 'Failed deployment lost its recovery manifest.'
Assert-Rejected { Run Configure } 'requires an Installed generation'
$installed = Run Install
Assert ($installed.state -eq 'Installed') 'Installation did not complete.'
$settingsAfter = Read-Json $settings
$steamAfter = Read-Json $steam
Assert ($settingsAfter.customShader.samplingFilter -eq 'FSR_EASU') 'Filter was not selected.'
Assert ($steamAfter.'steam.app.438100'.resolutionScale -eq 67) 'VRChat pixel percentage was not set.'
Assert ($steamAfter.steamvr.resolutionScale -eq 150 -and $steamAfter.steamvr.preferredRefreshRate -eq 120) 'Global resolution/refresh changed.'
$manifest = Read-Json (Join-Path $backup 'current.json')
$originalManifestPath = Join-Path $manifest.backupDirectory 'original-manifest.json'
$originalManifestHash = Hash $originalManifestPath
$null = Run Install
$manifestAgain = Read-Json (Join-Path $backup 'current.json')
Assert ($manifestAgain.backupDirectory -eq $manifest.backupDirectory) 'Repeated install created a new original backup.'
Assert ((Hash $originalManifestPath) -eq $originalManifestHash) 'Repeated install replaced the original property ledger.'

$manifestFile = Join-Path $backup 'current.json'
$beforeConfigureManifest = Hash $manifestFile
$beforeConfigureSteam = Hash $steam
$beforeConfigureCustom = Hash $settings
$installedShader = Hash (Join-Path $shaders 'distort_ps_layered.hlsl')
$installedInclude = Hash (Join-Path $shaders 'psvr2_easu.hlsl')
$preview = Run Configure -ResolutionScale 75 -DryRun
Assert (@($preview.properties | Where-Object file -eq 'steamVr')[0].installed -eq 75) 'Configure preview did not show the requested value.'
Assert ((Hash $manifestFile) -eq $beforeConfigureManifest -and (Hash $steam) -eq $beforeConfigureSteam) 'Configure dry run modified files.'
Assert-Rejected { Run Configure -SkipResolutionScale } 'SkipResolutionScale is only an Install option'
$fixtureProcesses = @([pscustomobject]@{ ProcessName = 'VRChat'; Id = 12345 })
Assert-Rejected { Run Configure -ResolutionScale 75 } 'Close SteamVR and VRChat'
$null = Run Configure -ResolutionScale 75 -DryRun
$fixtureProcesses = @()
$lockedSteam = [IO.File]::Open($steam, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try { Assert-Rejected { Run Configure -ResolutionScale 75 } 'changed files were rolled back' }
finally { $lockedSteam.Dispose() }
Assert ((Hash $manifestFile) -eq $beforeConfigureManifest -and (Hash $steam) -eq $beforeConfigureSteam) 'Failed Configure did not restore manifest/settings exactly.'
$configured = Run Configure -ResolutionScale 75
Assert ($configured.changed -and $configured.state -eq 'Installed') 'Configure did not complete.'
Assert ((Read-Json $steam).'steam.app.438100'.resolutionScale -eq 75) 'Configure did not set resolution.'
$configuredManifestHash = Hash $manifestFile
Assert (-not (Run Configure -ResolutionScale 75).changed) 'Same-value Configure was not a no-op.'
Assert ((Hash $manifestFile) -eq $configuredManifestHash) 'Same-value Configure rewrote its manifest.'
Assert ((Hash $settings) -eq $beforeConfigureCustom -and (Hash (Join-Path $shaders 'distort_ps_layered.hlsl')) -eq $installedShader -and
    (Hash (Join-Path $shaders 'psvr2_easu.hlsl')) -eq $installedInclude) 'Configure changed custom headset settings or shaders.'
Assert ((Hash $originalManifestPath) -eq $originalManifestHash) 'Configure changed the immutable original manifest.'
$scaleLedger = @((Read-Json $manifestFile).properties | Where-Object file -eq 'steamVr')[0]
Assert (-not $scaleLedger.existed -and $null -eq $scaleLedger.original) 'Configure lost the originally absent resolution value.'
Assert-Rejected { Run Install } 'Use Configure to change resolution'
$null = Run Install -ResolutionScale 75

$patchPath = Join-Path $shaders 'psvr2_easu.hlsl'
$patchBytes = [IO.File]::ReadAllBytes($patchPath)
[IO.File]::AppendAllText($patchPath, '// later foreign edit', $utf8)
Assert-Rejected { Run Configure -ResolutionScale 80 } 'differs from the recorded patch generation'
Assert-Rejected { Run Uninstall } 'differs from the recorded patch generation'
Assert ((Read-Json $settings).customShader.samplingFilter -eq 'FSR_EASU') 'Rejected uninstall changed config.'
[IO.File]::WriteAllBytes($patchPath, $patchBytes)
$changed = Read-Json $settings
$changed.customShader.samplingFilter = 'LANCZOS'
Write-Json $settings $changed
Assert-Rejected { Run Configure -ResolutionScale 80 } 'Managed setting changed'
Assert-Rejected { Run Uninstall } 'Managed setting changed'
$changed.customShader.samplingFilter = 'FSR_EASU'
$changed | Add-Member -NotePropertyName laterUnrelated -NotePropertyValue 'keep me'
Write-Json $settings $changed
$steamChanged = Read-Json $steam
$steamChanged.'steam.app.438100' | Add-Member -NotePropertyName laterOption -NotePropertyValue 123
Write-Json $steam $steamChanged
$removed = Run Uninstall
Assert ($removed.state -eq 'Uninstalled') 'Uninstall did not complete.'
Assert ((Hash (Join-Path $shaders 'distort_ps_layered.hlsl')) -eq $initialShader) 'Original shader was not restored exactly.'
Assert (-not (Test-Path -LiteralPath $patchPath)) 'New patch include was not removed.'
$restored = Read-Json $settings
Assert ($restored.customShader.samplingFilter -eq 'FXAA2CAS' -and $null -eq $restored.customShader.enableForOther) 'Original values (including null) were not restored.'
Assert (-not (Has $restored.customShader 'enableFilterForOverlay') -and -not (Has $restored.customShader 'enableFilterForDashboard')) 'Originally absent properties survived uninstall.'
Assert ($restored.laterUnrelated -eq 'keep me' -and $restored.customShader.colorMultiplier.red -eq 0.8) 'Unrelated settings were lost.'
$steamRestored = Read-Json $steam
Assert (-not (Has $steamRestored.'steam.app.438100' 'resolutionScale')) 'Originally absent resolution property survived uninstall.'
Assert ($steamRestored.'steam.app.438100'.laterOption -eq 123 -and $steamRestored.steamvr.resolutionScale -eq 150) 'Unrelated SteamVR settings were lost.'
Assert (-not (Run Uninstall).changed) 'Repeated uninstall was not a no-op.'

# A new cycle may start from absent sections, but prior immutable backups survive.
Write-Json $settings @{ unrelated = 'retained' }
Write-Json $steam @{ steamvr = @{ preferredRefreshRate = 120 } }
$null = Run Install
$secondManifest = Read-Json (Join-Path $backup 'current.json')
Assert ($secondManifest.backupDirectory -ne $manifest.backupDirectory) 'A new cycle reused original backups.'
$null = Run Uninstall
Assert (-not (Has (Read-Json $settings) 'customShader')) 'Originally absent empty shader section was not removed.'
Assert (-not (Has (Read-Json $steam) 'steam.app.438100')) 'Originally absent empty application section was not removed.'
Assert ((Hash $originalManifestPath) -eq $originalManifestHash) 'Old original backup was overwritten.'

# Start resolution management after an Install -SkipResolutionScale. The current
# (possibly user-updated) value becomes the original; other original backups stay immutable.
Write-Json $settings @{ unrelated = 'skip-cycle' }
Write-Json $steam @{ 'steam.app.438100' = @{ resolutionScale = 88; fovScale = 90 }; steamvr = @{ preferredRefreshRate = 120 } }
$null = Run Install -SkipResolutionScale
$skipManifest = Read-Json $manifestFile
$skipOriginal = Join-Path $skipManifest.backupDirectory 'original-manifest.json'
$skipOriginalHash = Hash $skipOriginal
$skipSteam = Read-Json $steam
$skipSteam.'steam.app.438100'.resolutionScale = 83
Write-Json $steam $skipSteam
$null = Run Configure -ResolutionScale 70
$skipScale = @((Read-Json $manifestFile).properties | Where-Object file -eq 'steamVr')[0]
Assert ($skipScale.existed -and $skipScale.original -eq 83 -and $skipScale.installed -eq 70) 'Configure after Skip captured the wrong original value.'
Assert ((Hash $skipOriginal) -eq $skipOriginalHash) 'Configure after Skip altered immutable original backups.'
$null = Run Configure -ResolutionScale 60
$null = Run Uninstall
Assert ((Read-Json $steam).'steam.app.438100'.resolutionScale -eq 83 -and (Read-Json $steam).'steam.app.438100'.fovScale -eq 90) 'Uninstall did not restore the first Configure original value.'

# Emulate power loss after journaling and after the settings atomic replace.
# Recovery must accept only the two recorded outcomes, and must retain originals.
function Prepare-InterruptedConfigure([int]$Scale, [switch]$ApplySettings) {
    $m = Read-Json $manifestFile
    $doc = Read-Json $steam
    $sectionPresent = Has $doc 'steam.app.438100'
    $present = $sectionPresent -and (Has $doc.'steam.app.438100' 'resolutionScale')
    $value = if ($present) { $doc.'steam.app.438100'.resolutionScale } else { $null }
    $old = @($m.properties | Where-Object file -eq 'steamVr')
    $entry = if ($old.Count) { $old[0] | ConvertTo-Json -Depth 50 | ConvertFrom-Json }
        else { [pscustomobject]@{ file = 'steamVr'; section = 'steam.app.438100'; name = 'resolutionScale'; sectionExisted = $sectionPresent; existed = $present; original = $value; installed = $Scale } }
    $entry.installed = $Scale
    $m | Add-Member -NotePropertyName pendingConfigure -NotePropertyValue ([pscustomobject]@{
        beforeSectionExisted = $sectionPresent; beforeExisted = $present; beforeValue = $value; entry = $entry; preparedUtc = 'fixture'
    }) -Force
    Write-Json $manifestFile $m
    if ($ApplySettings) {
        if (-not $sectionPresent) { $doc | Add-Member -NotePropertyName 'steam.app.438100' -NotePropertyValue ([pscustomobject]@{}) }
        $doc.'steam.app.438100' | Add-Member -NotePropertyName resolutionScale -NotePropertyValue $Scale -Force
        Write-Json $steam $doc
    }
}
$null = Run Install
Prepare-InterruptedConfigure 72
Assert-Rejected { Run Install } 'Configure transaction is pending'
Assert-Rejected { Run Configure -ResolutionScale 71 } 'Repeat Configure -ResolutionScale 72'
$null = Run Configure -ResolutionScale 72
Assert (-not (Has (Read-Json $manifestFile) 'pendingConfigure') -and (Read-Json $steam).'steam.app.438100'.resolutionScale -eq 72) 'Pre-write Configure recovery failed.'
Prepare-InterruptedConfigure 74 -ApplySettings
$null = Run Configure -ResolutionScale 74
Assert (-not (Has (Read-Json $manifestFile) 'pendingConfigure')) 'Post-write Configure recovery retained the journal.'
Prepare-InterruptedConfigure 76 -ApplySettings
$outsideEdit = Read-Json $steam
$outsideEdit.'steam.app.438100'.resolutionScale = 79
Write-Json $steam $outsideEdit
Assert-Rejected { Run Configure -ResolutionScale 76 } 'outside the pending Configure transaction'
$outsideEdit.'steam.app.438100'.resolutionScale = 76
Write-Json $steam $outsideEdit
$null = Run Uninstall
Assert ((Read-Json $steam).'steam.app.438100'.resolutionScale -eq 83) 'Uninstall during pending Configure lost the original value.'

# Pending first Configure after Skip must also be uninstallable before its write.
Write-Json $steam @{ steamvr = @{ preferredRefreshRate = 120 } }
$null = Run Install -SkipResolutionScale
Prepare-InterruptedConfigure 80
$null = Run Uninstall
Assert (-not (Has (Read-Json $steam) 'steam.app.438100')) 'Pending first Configure failed to restore section absence.'
foreach ($path in @($settings, $steam)) {
    $bytes = [IO.File]::ReadAllBytes($path)
    Assert (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'JSON has a UTF-8 BOM.'
}
[pscustomobject]@{ result = 'PASS'; fixtureRoot = $FixtureRoot; checks = 'Install/uninstall; Configure and unchanged values; scoped stopped-process guard; dry run; OS-failure rollback; original ledger preservation; Skip adoption; pending Configure recovery before/after atomic write and uninstall; foreign edits; null/absence restoration; UTF-8 without BOM.' } | ConvertTo-Json
