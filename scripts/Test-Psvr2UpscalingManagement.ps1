#Requires -Version 5.1
<# Exercises real deployment/rollback behavior against an isolated fake runtime.
   Does not change the installed SteamVR runtime or user configuration. #>
[CmdletBinding()]
param([string]$FixtureRoot = (Join-Path $env:TEMP ('psvr2-easu-test-' + [guid]::NewGuid().ToString('N'))))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$manager = Join-Path $PSScriptRoot 'Manage-Psvr2Upscaling.ps1'
$project = Split-Path -Parent $PSScriptRoot
$baseline = Join-Path $project 'research\CustomHeadsetOpenVR\CustomHeadsetOpenVR\DriverFiles\resources\shaders\d3d11\distort_ps_layered.hlsl'
if (-not (Test-Path -LiteralPath $baseline)) { throw "Inspected original shader is required: $baseline" }
if (@(Get-Process -Name vrserver, vrcompositor, VRChat -ErrorAction SilentlyContinue).Count -gt 0) {
    throw 'Close SteamVR and VRChat before running fixture tests; the production process guard is intentionally retained.'
}
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
function Write-Json([string]$Path, $Value) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 50), $utf8) }
function Read-Json([string]$Path) { return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json) }
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Has($Object, [string]$Name) { return $null -ne $Object.PSObject.Properties[$Name] }
function Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Run([string]$Action, [switch]$DryRun) {
    return (& $manager -Action $Action -DryRun:$DryRun -SourceRoot $source -OpenVrPaths $vrpaths -CustomHeadsetSettings $settings -BackupRoot $backup | ConvertFrom-Json)
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

$patchPath = Join-Path $shaders 'psvr2_easu.hlsl'
$patchBytes = [IO.File]::ReadAllBytes($patchPath)
[IO.File]::AppendAllText($patchPath, '// later foreign edit', $utf8)
Assert-Rejected { Run Uninstall } 'differs from the recorded patch generation'
Assert ((Read-Json $settings).customShader.samplingFilter -eq 'FSR_EASU') 'Rejected uninstall changed config.'
[IO.File]::WriteAllBytes($patchPath, $patchBytes)
$changed = Read-Json $settings
$changed.customShader.samplingFilter = 'LANCZOS'
Write-Json $settings $changed
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
foreach ($path in @($settings, $steam)) {
    $bytes = [IO.File]::ReadAllBytes($path)
    Assert (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'JSON has a UTF-8 BOM.'
}
[pscustomobject]@{ result = 'PASS'; fixtureRoot = $FixtureRoot; checks = 'Dry run, forced partial-write rollback, prepared-state recovery, install, immutable repeat, foreign shader conflict, property conflict, property-only uninstall, null/absence restoration, new cycle, UTF-8 without BOM.' } | ConvertTo-Json
