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

static float2 hash2(float2 p) {
    p = float2(dot(p, float2(127.1, 311.7)), dot(p, float2(269.5, 183.3)));
    return fract(sin(p) * 43758.5453);
}

// 1 on Voronoi cell edges, 0 inside cells: frost crystals.
static float voronoiEdge(float2 x) {
    float2 cell = floor(x), local = fract(x);
    float nearest = 8.0, second = 8.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 offset = float2(i, j);
            float2 r = offset + hash2(cell + offset) - local;
            float d = dot(r, r);
            if (d < nearest) { second = nearest; nearest = d; } else if (d < second) { second = d; }
        }
    }
    return 1.0 - smoothstep(0.0, 0.09, sqrt(second) - sqrt(nearest));
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

[[ stitchable ]] half4 water(float2 position, SwiftUI::Layer layer, float4 bounds,
                             float time, float level,
                             device const float *heights, int heightCount,
                             device const float *particles, int particleFloats,
                             float4 hang, float clarity, float frost, half4 tint, float heat)
{
    float2 size = bounds.zw;
    half4 base = layer.sample(position);

    float surfaceY = size.y * (1.0 - level) - heightAt(position.x, size.x, heights, heightCount);
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
        field = smoothMin(field, d, 4.0 + p.z * 0.8);
    }

    if (hang.z > 0.5) {
        float dropDistance = length(position - hang.xy) - hang.z;
        // A short neck at the rim so the droplet clings to the top edge.
        float lip = max(position.y - 1.5, abs(position.x - hang.x) - hang.z * 0.75);
        field = smoothMin(field, smoothMin(dropDistance, lip, 7.0), 8.0);
        if (dropDistance < nearestDistance) { nearestDistance = dropDistance; lensCenter = hang.xy; lensRadius = hang.z; }
    }

    if (field > 1.5) {
        if (heat < 0.01) return base;
        // Heat haze above the water: shimmering air and a warm glow, strongest near the surface.
        float above = max(surfaceY - position.y, 0.0);
        float strength = heat * exp(-above / max(size.y * 0.35, 1.0));
        float2 shimmer = float2(sin(position.y * 0.11 + time * 5.0) + sin(position.y * 0.23 - time * 3.1), 0.0);
        half4 hazy = layer.sample(position + shimmer * strength * 1.8);
        return mix(hazy, half4(1.0, 0.62, 0.30, 1.0), half(strength * 0.16));
    }

    // ---- Inside the water ----
    float depth = max(position.y - surfaceY, 0.0);
    float nearSurface = exp(-depth / 60.0);
    float slope = (heightAt(position.x - 2.0, size.x, heights, heightCount)
                   - heightAt(position.x + 2.0, size.x, heights, heightCount)) * 0.25;

    float2 offset = float2(slope * 22.0 * nearSurface, abs(slope) * 6.0 * nearSurface);
    offset += float2(sin(position.y * 0.045 + time * 1.3), cos(position.x * 0.038 - time * 1.1)) * 1.6;

    bool inDrop = bodyField > 0.0;
    if (inDrop && lensRadius > 0.0) {
        offset = -(position - lensCenter) / max(lensRadius, 1.0) * lensRadius * 0.6; // droplets act as lenses
    }

    half4 refracted = layer.sample(position + offset);
    float murk = 1.0 - clarity;
    if (murk > 0.01) {
        half4 blurred = (layer.sample(position + offset + float2( 5.0,  3.0)) +
                         layer.sample(position + offset + float2(-4.0,  5.0)) +
                         layer.sample(position + offset + float2( 3.0, -5.0)) +
                         layer.sample(position + offset + float2(-5.0, -3.0))) * 0.25h;
        refracted = mix(refracted, blurred, half(murk));
    }

    float deep = smoothstep(0.0, size.y * 0.8, depth);
    half3 color = mix(refracted.rgb, tint.rgb, half(0.20 + 0.40 * deep));
    color = mix(color, half3(0.34, 0.31, 0.20), half(murk * (0.40 + 0.30 * deep)));

    // Caustics only in clear water.
    color += half3(caustic(position * 0.018, time * 0.8) * clarity * (0.30 + 0.70 * nearSurface) * 0.24);

    // Sub-surface glow just under the meniscus.
    if (!inDrop) { color += half3(exp(-depth / 9.0) * 0.12); }

    // Bubbles.
    for (int k = 0; k < particleCount; k++) {
        float4 p = float4(particles[k * 4], particles[k * 4 + 1], particles[k * 4 + 2], particles[k * 4 + 3]);
        if (p.w != 1.0) continue;
        float d = length(position - p.xy);
        float ring = 1.0 - smoothstep(0.0, 1.2, abs(d - p.z));
        float fill = (1.0 - smoothstep(0.0, p.z, d)) * 0.10;
        float highlight = 1.0 - smoothstep(0.0, p.z * 0.32, length(position - p.xy + float2(p.z * 0.38)));
        color += half3(ring * 0.50 + fill + highlight * 0.45);
    }

    // Meniscus and droplet rims, plus foam on steep crests.
    float rim = 1.0 - smoothstep(0.0, 2.2, abs(field));
    float foam = smoothstep(0.35, 1.2, abs(slope)) * exp(-depth / 6.0);
    color = mix(color, half3(1.0), half(saturate(rim * 0.65 + foam * 0.5)));

    if (frost > 0.01) {
        float mask = frost * (0.22 + 0.78 * voronoiEdge(position * 0.045));
        color = mix(color, half3(0.90, 0.95, 1.0), half(mask * 0.55));
    }

    float alpha = (inDrop && hang.w > 0.0 && hang.w < 0.75 && lensRadius == hang.z) ? 0.55 : 1.0;
    float coverage = (1.0 - smoothstep(-0.8, 0.8, field)) * alpha;
    return mix(base, half4(color, 1.0), half(coverage));
}
