// Water.metal — SwiftUI layer effect that renders a side-view body of water over a layer.
//
// Inputs come from WaterSurface (CPU simulation): a row of surface heights, packed particles
// [x, y, radius, kind] (kind 0 = drop/spray metaball, 1 = bubble) and a hanging droplet
// [x, y, radius, alpha].

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Polynomial smooth minimum: merges signed distance fields like liquid (metaballs).
static float smoothMin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

// Catmull-Rom sample of the surface height row at x (points).
static float heightAt(float x, float width, device const float *heights, int count) {
    float position = clamp(x / max(width, 1.0), 0.0, 1.0) * float(count - 1);
    int i1 = int(floor(position));
    int i2 = min(i1 + 1, count - 1);
    int i0 = max(i1 - 1, 0);
    int i3 = min(i1 + 2, count - 1);
    float t = position - float(i1);
    float p0 = heights[i0], p1 = heights[i1], p2 = heights[i2], p3 = heights[i3];
    return 0.5 * ((2.0 * p1) + (-p0 + p2) * t
                  + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t * t
                  + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t * t * t);
}

// Cheap domain-warped caustic network.
static float caustic(float2 p, float t) {
    float2 q = p;
    float accumulated = 0.0;
    for (int k = 0; k < 3; k++) {
        float fk = float(k);
        q += float2(sin(q.y * 1.7 + t * 0.9 + fk), cos(q.x * 1.3 - t * 0.7 + fk * 2.1)) * 0.6;
        accumulated += abs(sin(q.x) * sin(q.y));
    }
    return pow(saturate(1.0 - accumulated / 3.0), 5.0);
}

// Sampling outside the layer returns transparent black and leaves dark seams at the glass.
static half4 sampleInterior(SwiftUI::Layer layer, float2 size, float2 position) {
    return layer.sample(clamp(position, float2(0.5), max(size - 0.5, float2(0.5))));
}

[[ stitchable ]] half4 water(float2 position, SwiftUI::Layer layer, float4 bounds,
                             float time, float level,
                             device const float *heights, int heightCount,
                             device const float *particles, int particleFloats,
                             float4 hang, float clarity, float frost, half4 tint, float heat, float compact, float opaque)
{
    float2 size = bounds.zw;
    half4 base = sampleInterior(layer, size, position);

    // Capillary rise at the glass is subtle and fades out for empty/full vessels.
    float wallDistance = min(position.x, size.x - position.x);
    float wetting = smoothstep(0.0, 0.06, level) * (1.0 - smoothstep(0.94, 1.0, level));
    float meniscus = exp(-wallDistance / mix(6.0, 2.0, compact)) * wetting * mix(1.4, 0.65, compact);
    float surfaceY = size.y * (1.0 - level) - heightAt(position.x, size.x, heights, heightCount) - meniscus;
    float bodyField = surfaceY - position.y; // < 0 inside the main body of water
    float field = bodyField;

    int particleCount = particleFloats / 4;
    float nearestDistance = 1e9;
    float2 lensCenter = float2(0.0);
    float lensRadius = 0.0;
    for (int k = 0; k < particleCount; k++) {
        float4 p = float4(particles[k * 4], particles[k * 4 + 1], particles[k * 4 + 2], particles[k * 4 + 3]);
        if (p.w != 0.0) continue;
        float d = length(position - p.xy) - p.z;
        if (d < nearestDistance) { nearestDistance = d; lensCenter = p.xy; lensRadius = p.z; }
        field = smoothMin(field, d, mix(2.5, 0.6, compact) + p.z * 0.3);
    }

    if (hang.z > 0.5) {
        float dropDistance = length(position - hang.xy) - hang.z;
        // A short neck at the rim so the droplet clings to the top edge.
        float lip = max(max(-position.y, position.y - hang.y), abs(position.x - hang.x) - hang.z * 0.18);
        field = smoothMin(field, smoothMin(dropDistance, lip, mix(3.0, 0.8, compact)), mix(3.0, 0.8, compact));
        if (dropDistance < nearestDistance) { nearestDistance = dropDistance; lensCenter = hang.xy; lensRadius = hang.z; }
    }

    if (field > 1.5) {
        if (heat < 0.01 || opaque > 0.5) return base;
        // Heat haze above the water: shimmering air and a warm glow, strongest near the surface.
        float above = max(surfaceY - position.y, 0.0);
        float strength = heat * exp(-above / max(size.y * 0.35, 1.0));
        float2 shimmer = float2(sin(position.y * 0.11 + time * 1.2) + sin(position.y * 0.23 - time * 0.9), 0.0);
        half4 hazy = sampleInterior(layer, size, position + shimmer * strength * 0.6);
        return mix(hazy, half4(1.0, 0.62, 0.30, 1.0), half(strength * 0.06));
    }

    // ---- Inside the water ----
    float depth = max(position.y - surfaceY, 0.0);
    float nearSurface = exp(-depth / 60.0);
    float slope = (heightAt(position.x - 2.0, size.x, heights, heightCount)
                   - heightAt(position.x + 2.0, size.x, heights, heightCount)) * 0.25;

    float2 offset = float2(clamp(slope, -0.8, 0.8) * 8.0, abs(slope) * 2.0) * nearSurface;

    bool inDrop = bodyField > 0.0;
    if (inDrop && lensRadius > 0.0) {
        offset = -(position - lensCenter) / max(lensRadius, 1.0) * lensRadius * 0.6; // droplets act as lenses
    }

    half4 refracted = opaque > 0.5 ? base : sampleInterior(layer, size, position + offset);
    float murk = 1.0 - clarity;
    if (murk > 0.01 && opaque < 0.5) {
        half4 blurred = (sampleInterior(layer, size, position + offset + float2( 5.0,  3.0)) +
                         sampleInterior(layer, size, position + offset + float2(-4.0,  5.0)) +
                         sampleInterior(layer, size, position + offset + float2( 3.0, -5.0)) +
                         sampleInterior(layer, size, position + offset + float2(-5.0, -3.0))) * 0.25h;
        refracted = mix(refracted, blurred, half(murk));
    }

    float deep = smoothstep(0.0, size.y * 0.8, depth);
    half3 color = mix(refracted.rgb, tint.rgb, half(0.12 + 0.24 * deep));
    color = mix(color, mix(tint.rgb, half3(0.40), 0.65h), half(murk * (0.28 + 0.20 * deep)));

    // Caustics only in clear water.
    if (compact < 0.5 && opaque < 0.5) {
        color += half3(caustic(position * 0.009, time * 0.16) * clarity * deep * 0.035);
    }

    // Sub-surface glow just under the meniscus.
    if (!inDrop) { color += half3(exp(-depth / mix(4.0, 1.5, compact)) * 0.045); }

    // Bubbles.
    for (int k = 0; k < particleCount; k++) {
        float4 p = float4(particles[k * 4], particles[k * 4 + 1], particles[k * 4 + 2], particles[k * 4 + 3]);
        if (p.w != 1.0) continue;
        float d = length(position - p.xy);
        float ring = 1.0 - smoothstep(0.0, 1.2, abs(d - p.z));
        float fill = (1.0 - smoothstep(0.0, p.z, d)) * 0.10;
        float highlight = 1.0 - smoothstep(0.0, p.z * 0.32, length(position - p.xy + float2(p.z * 0.38)));
        color += half3(ring * 0.18 + fill * 0.4 + highlight * 0.22);
    }

    // Meniscus and droplet rims, plus foam on steep crests.
    float rim = 1.0 - smoothstep(0.0, mix(1.1, 0.65, compact), abs(field));
    float foam = smoothstep(0.35, 1.2, abs(slope)) * exp(-depth / 6.0);
    color = mix(color, half3(1.0), half(saturate(rim * 0.28 + foam * 0.12)));

    if (frost > 0.01) {
        // A soft veil gathers against the glass; sharp crystal networks read as cracked glass.
        float edgeFrost = exp(-wallDistance / 12.0) + exp(-(size.y - position.y) / 10.0);
        float mask = frost * (0.12 + 0.10 * saturate(edgeFrost));
        color = mix(color, half3(0.90, 0.95, 1.0), half(mask));
    }

    float alpha = (inDrop && hang.w > 0.0 && hang.w < 0.75 && lensRadius == hang.z) ? 0.55 : 1.0;
    float coverage = (1.0 - smoothstep(-0.8, 0.8, field)) * alpha;
    return mix(base, half4(color, 1.0), half(coverage));
}
