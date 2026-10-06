param(
    [ValidateSet('Status','Install','Configure','Uninstall')][string]$Action = 'Status',
    [int]$ResolutionScale = 67,
    [switch]$SkipResolutionScale,
    [switch]$DryRun,
    [Parameter(Mandatory=$true)][string]$ResultPath
)
$ErrorActionPreference = 'Stop'
try {
    $output = & (Join-Path $PSScriptRoot 'Manage-Psvr2Upscaling.ps1') -Action $Action -ResolutionScale $ResolutionScale -SkipResolutionScale:$SkipResolutionScale -DryRun:$DryRun
    $result = [pscustomobject]@{ success=$true; result=($output | Out-String | ConvertFrom-Json) }
} catch {
    $result = [pscustomobject]@{ success=$false; error=$_.Exception.Message; detail=$_.ScriptStackTrace }
}
$temporaryResult = $ResultPath + '.tmp'
[IO.File]::WriteAllText($temporaryResult, ($result | ConvertTo-Json -Depth 50), [Text.UTF8Encoding]::new($false))
[IO.File]::Move($temporaryResult, $ResultPath)
