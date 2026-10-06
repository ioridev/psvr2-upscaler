param([Parameter(Mandatory=$true)][string]$OutputPath)
$ErrorActionPreference = 'Stop'
$configPath = Join-Path $env:APPDATA 'CustomHeadset\settings.json'
$paths = Get-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'openvr\openvrpaths.vrpath') -Raw | ConvertFrom-Json
$shaderDir = Join-Path $paths.runtime[0] 'drivers\CustomHeadsetOpenVR\resources\shaders\d3d11'
$settings = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$steamSettings = Get-Content -LiteralPath (Join-Path $paths.config[0] 'steamvr.vrsettings') -Raw | ConvertFrom-Json
$result = [pscustomobject]@{
    appData = $env:APPDATA
    configPath = $configPath
    configBytes = [IO.File]::ReadAllBytes($configPath).Length
    customShader = $settings.customShader
    shaderHashes = @(Get-ChildItem -LiteralPath $shaderDir -Filter '*.hlsl' -File | Get-FileHash -Algorithm SHA256 | Select-Object Path,Hash)
    steamVrSettings = $steamSettings.steamvr
    vrchatSettings = $steamSettings.'steam.app.438100'
    backupManifestExists = Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'PSVR2Upscaling\current.json')
}
$result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
