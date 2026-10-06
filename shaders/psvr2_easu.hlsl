// PSVR2 compositor integration of AMD FidelityFX FSR 1 EASU.
// Source: https://github.com/GPUOpen-Effects/FidelityFX-FSR/blob/
// a21ffb8f6c13233ba336352bdff293894c706575/ffx-fsr/ffx_fsr1.h
// Adaptations: continuous distortion UVs, explicit texture/eye bounds,
// safe exact reciprocals, linear-input conversion, and minification bypass.
// This is EASU spatial reconstruction only, without the separate RCAS pass.
//
// Copyright (c) 2021 Advanced Micro Devices, Inc. All rights reserved.
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#ifndef PSVR2_EASU_HLSL
#define PSVR2_EASU_HLSL

float3 Psvr2EasuLoad(Texture2D<float4> tex, int2 pixel,
                    int2 minimumPixel, int2 maximumPixel, bool inputIsGamma)
{
    float3 color = max(tex.Load(int3(clamp(pixel, minimumPixel, maximumPixel), 0)).rgb, 0.0);
    // EASU expects a perceptual, display-referred LDR signal. SteamVR can
    // supply linear texture views, so use a reversible gamma-2 bridge there.
    return inputIsGamma ? color : sqrt(color);
}

float Psvr2EasuLuma(float3 color)
{
    return color.g + 0.5 * (color.r + color.b);
}

void Psvr2EasuDirection(inout float2 direction, inout float edgeLength,
                       float weight, float lA, float lB, float lC, float lD, float lE)
{
    float dirX = lD - lB;
    float lenX = saturate(abs(dirX) / max(max(abs(lD - lC), abs(lC - lB)), 1.0e-8));
    float dirY = lE - lA;
    float lenY = saturate(abs(dirY) / max(max(abs(lE - lC), abs(lC - lA)), 1.0e-8));
    direction += float2(dirX, dirY) * weight;
    edgeLength += (lenX * lenX + lenY * lenY) * weight;
}

void Psvr2EasuTap(inout float3 colorSum, inout float weightSum,
                 float2 offset, float2 direction, float2 kernelLength,
                 float lobe, float clipDistance, float3 color)
{
    float2 rotated = float2(dot(offset, direction),
                           dot(offset, float2(-direction.y, direction.x))) * kernelLength;
    float distanceSquared = min(dot(rotated, rotated), clipDistance);
    float base = (2.0 / 5.0) * distanceSquared - 1.0;
    float window = lobe * distanceSquared - 1.0;
    base = (25.0 / 16.0) * base * base - (25.0 / 16.0 - 1.0);
    float weight = base * window * window;
    colorSum += color * weight;
    weightSum += weight;
}

// uvBounds is (minimumU, minimumV, maximumU, maximumV), not center/half-size.
// uvDx and uvDy are the derivatives of this channel's distortion UV.
// inputIsGamma describes the values returned by the texture view (SRGB views
// already decode on read). The returned values have the same encoding.
// Alpha remains the original bilinear alpha; EASU reconstructs RGB only.
float4 Psvr2Easu(Texture2D<float4> tex, SamplerState samp,
                 float2 uv, float2 inputSize, float4 uvBounds,
                 float2 uvDx, float2 uvDy, bool inputIsGamma)
{
    inputSize = max(inputSize, 1.0);
    int2 textureMaximum = int2(inputSize) - 1;
    int2 minimumPixel = clamp(int2(ceil(uvBounds.xy * inputSize - 0.5)), int2(0, 0), textureMaximum);
    int2 maximumPixel = clamp(int2(floor(uvBounds.zw * inputSize - 0.5)), minimumPixel, textureMaximum);
    float2 clampedUv = clamp(uv, (float2(minimumPixel) + 0.5) / inputSize,
                                (float2(maximumPixel) + 0.5) / inputSize);
    float4 bilinear = tex.SampleLevel(samp, clampedUv, 0.0);

    // The largest singular value of the source-texel Jacobian detects
    // minification even under a rotated/sheared distortion mapping. EASU
    // is an upsampler; retain normal sampling in minified parts of the lens.
    float2 sourceDx = uvDx * inputSize;
    float2 sourceDy = uvDy * inputSize;
    float j00 = dot(sourceDx, sourceDx);
    float j11 = dot(sourceDy, sourceDy);
    float j01 = dot(sourceDx, sourceDy);
    float largestSquared = 0.5 * (j00 + j11 +
        sqrt(max((j00 - j11) * (j00 - j11) + 4.0 * j01 * j01, 0.0)));
    float4 outputColor = bilinear;
    [branch]
    if (largestSquared <= 1.0001)
    {

    float2 sourcePosition = clampedUv * inputSize - 0.5;
    int2 origin = int2(floor(sourcePosition));
    float2 fraction = sourcePosition - floor(sourcePosition);

    // AMD's twelve-tap EASU neighborhood:
    //       b c
    //     e f g h
    //     i j k l
    //       n o
    float3 b = Psvr2EasuLoad(tex, origin + int2( 0,-1), minimumPixel, maximumPixel, inputIsGamma);
    float3 c = Psvr2EasuLoad(tex, origin + int2( 1,-1), minimumPixel, maximumPixel, inputIsGamma);
    float3 e = Psvr2EasuLoad(tex, origin + int2(-1, 0), minimumPixel, maximumPixel, inputIsGamma);
    float3 f = Psvr2EasuLoad(tex, origin + int2( 0, 0), minimumPixel, maximumPixel, inputIsGamma);
    float3 g = Psvr2EasuLoad(tex, origin + int2( 1, 0), minimumPixel, maximumPixel, inputIsGamma);
    float3 h = Psvr2EasuLoad(tex, origin + int2( 2, 0), minimumPixel, maximumPixel, inputIsGamma);
    float3 i = Psvr2EasuLoad(tex, origin + int2(-1, 1), minimumPixel, maximumPixel, inputIsGamma);
    float3 j = Psvr2EasuLoad(tex, origin + int2( 0, 1), minimumPixel, maximumPixel, inputIsGamma);
    float3 k = Psvr2EasuLoad(tex, origin + int2( 1, 1), minimumPixel, maximumPixel, inputIsGamma);
    float3 l = Psvr2EasuLoad(tex, origin + int2( 2, 1), minimumPixel, maximumPixel, inputIsGamma);
    float3 n = Psvr2EasuLoad(tex, origin + int2( 0, 2), minimumPixel, maximumPixel, inputIsGamma);
    float3 o = Psvr2EasuLoad(tex, origin + int2( 1, 2), minimumPixel, maximumPixel, inputIsGamma);

    float2 direction = 0.0;
    float edgeLength = 0.0;
    Psvr2EasuDirection(direction, edgeLength, (1.0-fraction.x)*(1.0-fraction.y),
        Psvr2EasuLuma(b), Psvr2EasuLuma(e), Psvr2EasuLuma(f), Psvr2EasuLuma(g), Psvr2EasuLuma(j));
    Psvr2EasuDirection(direction, edgeLength, fraction.x*(1.0-fraction.y),
        Psvr2EasuLuma(c), Psvr2EasuLuma(f), Psvr2EasuLuma(g), Psvr2EasuLuma(h), Psvr2EasuLuma(k));
    Psvr2EasuDirection(direction, edgeLength, (1.0-fraction.x)*fraction.y,
        Psvr2EasuLuma(f), Psvr2EasuLuma(i), Psvr2EasuLuma(j), Psvr2EasuLuma(k), Psvr2EasuLuma(n));
    Psvr2EasuDirection(direction, edgeLength, fraction.x*fraction.y,
        Psvr2EasuLuma(g), Psvr2EasuLuma(j), Psvr2EasuLuma(k), Psvr2EasuLuma(l), Psvr2EasuLuma(o));

    float directionSquared = dot(direction, direction);
    direction = directionSquared < (1.0 / 32768.0)
        ? float2(1.0, 0.0) : direction * rsqrt(max(directionSquared, 1.0e-8));
    edgeLength *= 0.5;
    edgeLength *= edgeLength;
    float stretch = dot(direction, direction) / max(max(abs(direction.x), abs(direction.y)), 1.0e-8);
    float2 kernelLength = float2(1.0 + (stretch - 1.0) * edgeLength, 1.0 - 0.5 * edgeLength);
    float lobe = 0.5 + ((0.25 - 0.04) - 0.5) * edgeLength;
    float clipDistance = 1.0 / max(lobe, 1.0e-8);

    float3 colorSum = 0.0;
    float weightSum = 0.0;
    Psvr2EasuTap(colorSum, weightSum, float2( 0,-1)-fraction, direction, kernelLength, lobe, clipDistance, b);
    Psvr2EasuTap(colorSum, weightSum, float2( 1,-1)-fraction, direction, kernelLength, lobe, clipDistance, c);
    Psvr2EasuTap(colorSum, weightSum, float2(-1, 0)-fraction, direction, kernelLength, lobe, clipDistance, e);
    Psvr2EasuTap(colorSum, weightSum, float2( 0, 0)-fraction, direction, kernelLength, lobe, clipDistance, f);
    Psvr2EasuTap(colorSum, weightSum, float2( 1, 0)-fraction, direction, kernelLength, lobe, clipDistance, g);
    Psvr2EasuTap(colorSum, weightSum, float2( 2, 0)-fraction, direction, kernelLength, lobe, clipDistance, h);
    Psvr2EasuTap(colorSum, weightSum, float2(-1, 1)-fraction, direction, kernelLength, lobe, clipDistance, i);
    Psvr2EasuTap(colorSum, weightSum, float2( 0, 1)-fraction, direction, kernelLength, lobe, clipDistance, j);
    Psvr2EasuTap(colorSum, weightSum, float2( 1, 1)-fraction, direction, kernelLength, lobe, clipDistance, k);
    Psvr2EasuTap(colorSum, weightSum, float2( 2, 1)-fraction, direction, kernelLength, lobe, clipDistance, l);
    Psvr2EasuTap(colorSum, weightSum, float2( 0, 2)-fraction, direction, kernelLength, lobe, clipDistance, n);
    Psvr2EasuTap(colorSum, weightSum, float2( 1, 2)-fraction, direction, kernelLength, lobe, clipDistance, o);

    // Clamp to the closest 2x2 input range to suppress negative-lobe ringing.
    float3 minimumColor = min(min(f, g), min(j, k));
    float3 maximumColor = max(max(f, g), max(j, k));
    float3 result = clamp(colorSum / max(weightSum, 1.0e-8), minimumColor, maximumColor);
    if (!inputIsGamma)
        result *= result;
    outputColor.rgb = result;
    }
    return outputColor;
}

#endif
