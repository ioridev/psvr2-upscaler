#include "../shaders/psvr2_easu.hlsl"

Texture2D<float4> Source : register(t0);
SamplerState LinearClamp : register(s0);
cbuffer TestParameters : register(b0) {
    float2 InputSize;
    float2 OutputSize;
    float4 EyeBounds;
    uint UseEasu;
    uint InputIsGamma;
    float2 Padding;
    float4 UvTransform;
};

#ifdef TEST_UPSTREAM
#define A_GPU 1
#define A_HLSL 1
#include "../research/FidelityFX-FSR/ffx-fsr/ffx_a.h"
#define FSR_EASU_F 1
AF4 FsrEasuRF(AF2 p) { return Source.GatherRed(LinearClamp, p, int2(0, 0)); }
AF4 FsrEasuGF(AF2 p) { return Source.GatherGreen(LinearClamp, p, int2(0, 0)); }
AF4 FsrEasuBF(AF2 p) { return Source.GatherBlue(LinearClamp, p, int2(0, 0)); }
#include "../research/FidelityFX-FSR/ffx-fsr/ffx_fsr1.h"
#endif

float4 VS(uint id : SV_VertexID) : SV_Position {
    float2 corner = float2((id << 1) & 2, id & 2);
    return float4(corner * float2(2, -2) + float2(-1, 1), 0, 1);
}

float4 PS(float4 position : SV_Position) : SV_Target {
    float2 span = EyeBounds.zw - EyeBounds.xy;
    float2 local = position.xy / OutputSize - 0.5;
    float2 transformed = UvTransform.xy * local.x + UvTransform.zw * local.y + 0.5;
    float2 uv = EyeBounds.xy + transformed * span;
#ifdef TEST_UPSTREAM
    if (UseEasu == 2) {
        uint4 c0, c1, c2, c3;
        FsrEasuCon(c0, c1, c2, c3, InputSize.x, InputSize.y,
            InputSize.x, InputSize.y, OutputSize.x, OutputSize.y);
        float3 rgb;
        FsrEasuF(rgb, uint2(position.xy), c0, c1, c2, c3);
        return float4(rgb, Source.SampleLevel(LinearClamp, uv, 0).a);
    }
#endif
    if (UseEasu != 0) {
        return Psvr2Easu(Source, LinearClamp, uv, InputSize, EyeBounds,
            UvTransform.xy * span / OutputSize.x,
            UvTransform.zw * span / OutputSize.y, InputIsGamma != 0);
    }
    float2 halfTexel = 0.5 / InputSize;
    return Source.SampleLevel(LinearClamp,
        clamp(uv, EyeBounds.xy + halfTexel, EyeBounds.zw - halfTexel), 0);
}
