[CmdletBinding()]
param(
    [string]$UpstreamRoot = (Join-Path $PSScriptRoot '..\external\CustomHeadsetOpenVR'),
    [switch]$Compile
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $UpstreamRoot 'CustomHeadsetOpenVR\DriverFiles\resources\shaders\d3d11\distort_ps_layered.hlsl'
$baselineHash = '65CAAA283BE3F4FD9B8F62459E2E73D5D3B5136E6448A635C518217003E902CB'
if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $baselineHash) {
    throw 'Upstream shader changed. Review integration against the new version before building.'
}
$text = [IO.File]::ReadAllText($source).Replace("`r`n", "`n")
function Replace-Once([string]$Before, [string]$After) {
    if (($script:text.Split(@($Before), [StringSplitOptions]::None).Count - 1) -ne 1) {
        throw "Expected one integration anchor: $Before"
    }
    $script:text = $script:text.Replace($Before, $After)
}
Replace-Once 'SHADER_VARIABLES' @'
SHADER_VARIABLES

// PSVR2 EASU integration. Upstream GPL-2.0 shader, modified 2026-10-06.
// Only scene sampling changes; SteamVR retains its original pose/optical pipeline.
#ifdef FILTER_FSR_EASU
#include "../psvr2_easu.hlsl"
// Dashboard layers stay at their own resolution and use the upstream sampler.
#ifndef NO_OVERLAY_FILTER
#define NO_OVERLAY_FILTER 1
#endif
#endif
'@
Replace-Once 'float4 sampleSceneTexture(in Texture2D<float4> tex, in float2 uv, in float2 dx, in float2 dy){' @'
float4 sampleSceneTexture(in Texture2D<float4> tex, in float2 uv, in float2 dx, in float2 dy, in float4 eyeBounds){
#ifdef FILTER_FSR_EASU
    uint inputWidth, inputHeight;
    tex.GetDimensions(inputWidth, inputHeight);
    return inputColorProcessor(Psvr2Easu(tex, g_sScene, uv,
        float2(inputWidth, inputHeight), eyeBounds, dx, dy,
        g_bSceneTextureRequiresGammaToLinearConversion != 0));
#else
'@
Replace-Once "`treturn inputColorProcessor(color);`n}`n`nfloat4 sampleSceneTextureBasic" "`treturn inputColorProcessor(color);`n#endif // FILTER_FSR_EASU`n}`n`nfloat4 sampleSceneTextureBasic"
Replace-Once "`tfloat4 col = 1;" @'
    // matTexDetails describes this eye's subrectangle, including atlas textures.
    // Clamp every EASU tap to this rectangle, not merely the whole resource.
    float4 eyeBounds = float4(0, 0, 1, 1);
#ifndef NO_DISTORTION
    float4 textureRange = g_SceneTextureData[IN.param4].eye[g_nEye].matTexDetails._m20_m21_m22_m23;
    eyeBounds = float4(textureRange.xy - textureRange.zw, textureRange.xy + textureRange.zw);
    float2 uvDxRed = uvDx;
    float2 uvDyRed = uvDy;
    float2 uvDxBlue = uvDx;
    float2 uvDyBlue = uvDy;
#ifdef FILTER_FSR_EASU
    uvDxRed = ddx(IN.uv1.xy);
    uvDyRed = ddy(IN.uv1.xy);
    uvDxBlue = ddx(IN.uv3.xy);
    uvDyBlue = ddy(IN.uv3.xy);
#endif
#endif
    float4 col = 1;
'@
$text = [regex]::Replace($text,
    '(sampleSceneTexture\(g_tScene[012], IN\.uv[123]\.xy, uvDx, uvDy)\)', '$1, eyeBounds)')
$text = [regex]::Replace($text,
    '(sampleSceneTexture\(g_tScene[012], IN\.uv1\.xy), uvDx, uvDy, eyeBounds\)\.x', '$1, uvDxRed, uvDyRed, eyeBounds).x')
$text = [regex]::Replace($text,
    '(sampleSceneTexture\(g_tScene[012], IN\.uv3\.xy), uvDx, uvDy, eyeBounds\)\.z', '$1, uvDxBlue, uvDyBlue, eyeBounds).z')
$text = [regex]::Replace($text,
    '(sampleSceneTexture\(g_tLayer, IN\.uv[123]\.zw, uvDxOverlay, uvDyOverlay)\)', '$1, float4(0, 0, 1, 1))')
Replace-Once "`tfloat4 textureRange = g_SceneTextureData[IN.param4].eye[g_nEye].matTexDetails._m20_m21_m22_m23;" "`t// textureRange was read above for both sampling bounds and edge clipping."
$shaderDir = Join-Path $root 'shaders'
$null = New-Item -ItemType Directory -Force -Path $shaderDir
$output = Join-Path $shaderDir 'distort_ps_layered.hlsl'
[IO.File]::WriteAllText($output, $text, [Text.UTF8Encoding]::new($false))
$null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'licenses')
Copy-Item -LiteralPath (Join-Path $UpstreamRoot 'LICENCE.md') -Destination (Join-Path $root 'licenses\CustomHeadsetOpenVR-GPL-2.0.txt')
Write-Output "Generated $output"
if (!$Compile) { return }

# Match the declarations decoded by the installed driver from real SteamVR bytecode.
# This validates the actual resource/register ABI, not fabricated shader stubs.
$paths = Get-Content -Raw -LiteralPath (Join-Path $env:LOCALAPPDATA 'openvr\openvrpaths.vrpath') | ConvertFrom-Json
$runtime = $paths.runtime[0]
$captureDir = Join-Path $runtime 'drivers\CustomHeadsetOpenVR\resources\shaders\d3d11\temp'
$fxc = Get-ChildItem -Path 'C:\Program Files (x86)\Windows Kits\10\bin\*\x64\fxc.exe' | Sort-Object FullName -Descending | Select-Object -First 1
if (!$fxc) { throw 'Windows SDK fxc.exe is required.' }
$buildDir = Join-Path $root 'artifacts\compositor-compile'
$tempDir = Join-Path $buildDir 'temp'
$null = New-Item -ItemType Directory -Force -Path $tempDir
Copy-Item -LiteralPath (Join-Path $shaderDir 'psvr2_easu.hlsl') -Destination $buildDir
$records = @()
foreach ($variant in @('distort_ps_layered', 'distort_ps_layered_mc', 'distort_ps_achromatic_nd')) {
    $captured = [IO.File]::ReadAllText((Join-Path $captureDir "$variant.processed.hlsl")).Replace("`r`n", "`n")
    $start = $captured.IndexOf('SamplerState ')
    $declarationMatch = [regex]::Match($captured, '(?s)SamplerState .*?struct OutputStruct\s*\{.*?\};')
    if ($start -lt 0 -or !$declarationMatch.Success) { throw "Missing real shader declarations: $variant" }
    $declarations = $declarationMatch.Value
    $processed = $text.Replace('SHADER_VARIABLES', $declarations)
    $processedPath = Join-Path $tempDir "$variant.processed.hlsl"
    [IO.File]::WriteAllText($processedPath, $processed, [Text.UTF8Encoding]::new($false))
    foreach ($filter in @('FSR_EASU', 'FXAA2CAS', 'None')) {
        $target = Join-Path $buildDir "$variant-$filter.fxo"
        $args = @('/nologo','/T','ps_5_0','/E','main','/O3','/D',"FILTER_$filter=1",'/D','NO_OVERLAY_FILTER=1')
        if ($filter -eq 'FXAA2CAS') { $args += @('/D','CAS_SHARPENING=1.0','/D','CAS_CONTRAST=1.0') }
        if ($variant -like '*_mc') { $args += @('/D','MURA_CORRECTION=1') }
        if ($variant -like '*_nd') { $args += @('/D','NO_DISTORTION=1','/D','NO_LAYER=1') }
        $args += @('/Fo',$target,$processedPath)
        $messages = & $fxc.FullName @args 2>&1
        $ok = $LASTEXITCODE -eq 0
        $records += [pscustomobject]@{ variant=$variant; filter=$filter; passed=$ok; bytecodeBytes=if($ok){(Get-Item $target).Length}else{0}; messages=($messages -join "`n") }
        if (!$ok) { $messages | Write-Output; throw "Shader compilation failed: $variant $filter" }
        Write-Output "Compiled $variant / $filter"
    }
}
$records | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $buildDir 'report.json') -Encoding UTF8
