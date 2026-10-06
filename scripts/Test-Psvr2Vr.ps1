[CmdletBinding(DefaultParameterSetName = 'Build')]
param(
    [Parameter(ParameterSetName = 'Run', Mandatory = $true)] [switch] $Run,
    [Parameter(ParameterSetName = 'Probe', Mandatory = $true)] [switch] $Probe,
    [ValidateRange(0.1, 600)] [double] $DurationSeconds = 20,
    # Pixel area ratio; each dimension is multiplied by sqrt(RenderScale).
    [ValidateRange(0.05, 2)] [double] $RenderScale = 0.67,
    [string] $ReportPath,
    [string] $SteamVrPath,
    [switch] $AllowSceneReplacement,
    # Read-only static lens mapping estimate, not measured shader execution.
    [switch] $DistortionCoverage,
    [ValidateRange(16, 32768)] [uint32] $PanelWidth = 2000,
    [ValidateRange(16, 32768)] [uint32] $PanelHeight = 2040,
    [ValidateRange(0, 32768)] [uint32] $CoverageInputWidth = 0,
    [ValidateRange(0, 32768)] [uint32] $CoverageInputHeight = 0,
    [ValidateRange(9, 129)] [uint32] $CoverageGrid = 41
)
$ErrorActionPreference = 'Stop'
if ([bool]$CoverageInputWidth -ne [bool]$CoverageInputHeight) {
    throw 'Set both CoverageInputWidth and CoverageInputHeight, or leave both zero to derive them from RenderScale.'
}
$workspace = Split-Path $PSScriptRoot -Parent
$buildPath = Join-Path $workspace 'build\vr-smoke'
$openVrRoot = Join-Path $workspace 'external\CustomHeadsetOpenVR\ThirdParty\openvr'
if (-not (Test-Path -LiteralPath (Join-Path $openVrRoot 'headers\openvr.h'))) {
    throw 'Initialize the pinned SDK: git -C external/CustomHeadsetOpenVR submodule update --init --depth 1 ThirdParty/openvr'
}
& cmake -S (Join-Path $workspace 'tests\vr-smoke') -B $buildPath -A x64
if ($LASTEXITCODE -ne 0) { throw 'VR smoke CMake configuration failed' }
& cmake --build $buildPath --config Release
if ($LASTEXITCODE -ne 0) { throw 'VR smoke build failed' }
$exe = Join-Path $buildPath 'Release\psvr2_vr_smoke.exe'
if (-not $SteamVrPath) {
    $pathsFile = Join-Path $env:LOCALAPPDATA 'openvr\openvrpaths.vrpath'
    if (Test-Path -LiteralPath $pathsFile) {
        $paths = Get-Content -LiteralPath $pathsFile -Raw | ConvertFrom-Json
        $SteamVrPath = @($paths.runtime)[0]
    }
}
if (-not $SteamVrPath) { throw 'Registered SteamVR runtime not found; use -SteamVrPath' }
$runtimeDll = Join-Path $SteamVrPath 'bin\win64\openvr_api.dll'
if (-not (Test-Path -LiteralPath $runtimeDll)) { throw "Runtime DLL not found: $runtimeDll" }
Copy-Item -LiteralPath $runtimeDll -Destination (Join-Path (Split-Path $exe) 'openvr_api.dll') -Force
& $exe --validate-shaders
if ($LASTEXITCODE -ne 0) { throw 'VR scene shader validation failed' }
if (-not ($Run -or $Probe)) {
    Write-Output "Built $exe. Use -Probe for a read-only runtime sample, or -Run for the headset scene."
    return
}
if (-not (Get-Process -Name vrserver -ErrorAction SilentlyContinue)) {
    throw 'SteamVR must already be running. This script does not launch or restart SteamVR.'
}
if ($Run -and -not $AllowSceneReplacement -and (Get-Process -Name VRChat -ErrorAction SilentlyContinue)) {
    throw 'VRChat is running. Close the VR session first, or explicitly use -AllowSceneReplacement to show the test scene.'
}
if (-not $ReportPath) {
    $mode = if ($Probe) { 'probe' } else { 'scene' }
    $ReportPath = Join-Path $workspace ("results\vr-{0}-{1}.json" -f $mode, (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
$reportDirectory = Split-Path $ReportPath -Parent
[System.IO.Directory]::CreateDirectory($reportDirectory) | Out-Null
$invariant = [System.Globalization.CultureInfo]::InvariantCulture
$runArgs = @('--duration', $DurationSeconds.ToString($invariant), '--pixel-scale', $RenderScale.ToString($invariant), '--report', $ReportPath)
if ($Probe) { $runArgs += '--probe' }
if ($DistortionCoverage) {
    $runArgs += @('--distortion-coverage', '--panel-width', "$PanelWidth", '--panel-height', "$PanelHeight", '--coverage-grid', "$CoverageGrid")
    if ($CoverageInputWidth) {
        $runArgs += @('--coverage-input-width', "$CoverageInputWidth", '--coverage-input-height', "$CoverageInputHeight")
    }
}
& $exe @runArgs
if ($LASTEXITCODE -ne 0) { throw "VR validation failed (exit $LASTEXITCODE); see $ReportPath" }
$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
# Do not echo the HMD serial captured in the local JSON diagnostic.
[pscustomobject]@{
    Success = $report.success
    Mode = $report.mode
    HmdModel = $report.hmd.model
    ActualTrackingSystem = $report.hmd.actualTrackingSystem
    HmdConnected = $report.hmd.connected
    DisplayFrequencyHz = $report.hmd.displayFrequencyHz
    SubmittedPerEye = $report.submittedPerEye
    AcceptedStereoFrames = $report.acceptedStereoFrames
    TimingSamples = $report.timing.uniqueSamples
    ReportPath = $ReportPath
}
