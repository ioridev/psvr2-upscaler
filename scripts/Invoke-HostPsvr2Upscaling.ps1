<#
Codex MSIX redirects APPDATA into its private LocalCache. SteamVR uses the
physical host APPDATA. Launch a hidden process via the Windows WMI process
provider so installation, backup and status all use SteamVR's filesystem view.
No elevation, process injection, policy changes, or credentials are involved.
#>
[CmdletBinding()]
param(
    [ValidateSet('Status','Install','Configure','Uninstall')][string]$Action = 'Status',
    [ValidateRange(20,100)][int]$ResolutionScale = 67,
    [switch]$SkipResolutionScale,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$outputDir = Join-Path $root 'artifacts\host-operations'
$null = New-Item -ItemType Directory -Force -Path $outputDir
$resultPath = Join-Path $outputDir (([guid]::NewGuid().ToString('N')) + '.json')
$workerPath = Join-Path $PSScriptRoot 'Invoke-HostPsvr2UpscalingWorker.ps1'
$exe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$command = '"{0}" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -Action {2} -ResolutionScale {3} -ResultPath "{4}"' -f $exe,$workerPath,$Action,$ResolutionScale,$resultPath
if ($SkipResolutionScale) { $command += ' -SkipResolutionScale' }
if ($DryRun) { $command += ' -DryRun' }
$startup = New-CimInstance -CimClass (Get-CimClass -ClassName Win32_ProcessStartup) -ClientOnly -Property @{ShowWindow=[uint16]0}
$launch = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$command;ProcessStartupInformation=$startup;CurrentDirectory=$root}
if ($launch.ReturnValue -ne 0) { throw "Host process launch failed: $($launch.ReturnValue)" }
$deadline = [DateTime]::UtcNow.AddSeconds(30)
while (!(Test-Path -LiteralPath $resultPath)) {
    if ([DateTime]::UtcNow -gt $deadline) { throw "Host operation has not returned; inspect PID $($launch.ProcessId) before retrying." }
    Start-Sleep -Milliseconds 200
}
$reply = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
if (!$reply.success) { throw "Host operation failed: $($reply.error) $($reply.detail)" }
$reply.result | ConvertTo-Json -Depth 50
