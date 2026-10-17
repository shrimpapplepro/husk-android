// SPDX-License-Identifier: GPL-2.0-or-later
// The loading background: a soft spectrum glowing out of black, computed per pixel per frame.
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
    // Centred, aspect-correct coordinates: the short side spans -0.5 .. 0.5.
    float2 uv = (position - 0.5 * size) / max(min(size.x, size.y), 1.0);

    // Five wide glows stacked top to bottom in spectrum order -- violet, blue, green, yellow, orange --
    // each drifting on its own slow orbit so the colours breathe into each other.
    const float hues[5] = { 0.78, 0.62, 0.36, 0.15, 0.06 };
    float3 light = float3(0.0);
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float y = mix(-0.55, 0.55, fi / 4.0);
        float2 centre = float2(0.18 * sin(time * 0.21 + fi * 1.7),
                               y + 0.08 * cos(time * 0.17 + fi * 2.3));
        float2 d = (uv - centre) * float2(1.0, 1.35);
        float glow = exp(-dot(d, d) * 5.5);
        float hue = fract(hues[i] + 0.015 * sin(time * 0.1 + fi));
        light += hueToRGB(hue) * glow;
    }

    // Fade to black toward the edges, then a soft tone curve so overlaps glow instead of clipping.
    float falloff = exp(-dot(uv * float2(1.0, 0.75), uv * float2(1.0, 0.75)) * 2.4);
    float3 rgb = light * falloff * 0.85;
    rgb = rgb / (1.0 + rgb);
    rgb = mix(float3(dot(rgb, float3(0.299, 0.587, 0.114))), rgb, 0.85);   // a touch less saturated

    // Dither, so the long dark gradients do not band.
    float noise = fract(sin(dot(position, float2(12.9898, 78.233))) * 43758.5453);
    rgb += (noise - 0.5) / 255.0;

    return half4(half3(max(rgb, 0.0)), 1.0);
}
