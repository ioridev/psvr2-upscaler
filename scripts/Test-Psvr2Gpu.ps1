[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\artifacts\gpu-validation')
)
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $output -Force | Out-Null
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'Visual Studio C++ tools are required for the hardware GPU test.' }
$developerModule = Join-Path $vs 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll'
Import-Module $developerModule
Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64' | Out-Null
$source = Join-Path $workspace 'tests\gpu_validation.cpp'
$exe = Join-Path $output 'gpu_validation.exe'
$obj = Join-Path $output 'gpu_validation.obj'
& cl.exe /nologo /std:c++17 /EHsc /O2 /W4 $source "/Fe:$exe" "/Fo:$obj" /link d3d11.lib d3dcompiler.lib dxgi.lib
if ($LASTEXITCODE -ne 0) { throw "GPU harness compilation failed ($LASTEXITCODE)." }
& $exe (Join-Path $workspace 'tests\gpu_validation.hlsl') $output | Tee-Object -FilePath (Join-Path $output 'run.log')
if ($LASTEXITCODE -ne 0) { throw "GPU validation failed ($LASTEXITCODE). See $output" }
Get-Content (Join-Path $output 'result.json') -Raw
