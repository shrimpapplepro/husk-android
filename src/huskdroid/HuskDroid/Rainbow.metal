// SPDX-License-Identifier: GPL-2.0-or-later
// The loading background: a rainbow that flows, computed per pixel per frame.
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

static float3 hueToRGB(float h)
{
    float3 k = fmod(float3(5.0, 3.0, 1.0) + h * 6.0, 6.0);
    return 1.0 - clamp(min(k, 4.0 - k), 0.0, 1.0);
}

[[ stitchable ]] half4 huskRainbow(float2 position, half4 color, float time, float2 size)
{
    float2 uv = position / max(size, float2(1.0));
    // Two slow waves bend the bands so they flow rather than slide.
    float bend = 0.10 * sin(uv.y * 5.0 + time * 0.9) + 0.07 * sin(uv.x * 7.0 - time * 0.6);
    float hue = fract(uv.x * 0.55 + uv.y * 0.45 + bend + time * 0.06);
    float3 rgb = hueToRGB(hue);
    // A soft light sweeping across, so it reads as lit rather than flat.
    float glow = 0.5 + 0.5 * sin((uv.x + uv.y) * 3.0 - time * 1.3);
    rgb = mix(rgb, float3(1.0), 0.12 + 0.10 * glow);
    // Darker toward the edges, so Android's text in the middle stays readable.
    float vignette = smoothstep(1.15, 0.25, length(uv - 0.5) * 1.6);
    return half4(half3(rgb * (0.55 + 0.45 * vignette)), 1.0);
}
