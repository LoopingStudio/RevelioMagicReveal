// Outils partagés par les shaders des masques.
#ifndef RevealCommon_h
#define RevealCommon_h

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// MARK: - Bruit

inline float rn_hash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

inline float2 rn_hash2(float2 p) {
    float n = rn_hash(p);
    return float2(n, rn_hash(p + n * 17.17));
}

inline float rn_noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = rn_hash(i);
    float b = rn_hash(i + float2(1, 0));
    float c = rn_hash(i + float2(0, 1));
    float d = rn_hash(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

inline float rn_fbm(float2 p, int octaves) {
    float sum = 0.0, amplitude = 0.5, norm = 0.0;
    for (int i = 0; i < octaves; i++) {
        sum += amplitude * rn_noise(p);
        norm += amplitude;
        p = p * 2.03 + float2(17.1, 9.2);
        amplitude *= 0.5;
    }
    return sum / norm;
}

/// Voronoï : x = distance au germe le plus proche, y = au deuxième, z = identifiant (0…1) de la cellule.
inline float3 rn_voronoi(float2 p) {
    float2 cell = floor(p);
    float2 f = fract(p);
    float d1 = 8.0, d2 = 8.0, id = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float2 g = float2(x, y);
            float2 o = rn_hash2(cell + g);
            float2 r = g + o - f;
            float d = dot(r, r);
            if (d < d1) { d2 = d1; d1 = d; id = rn_hash(cell + g + 3.7); }
            else if (d < d2) { d2 = d; }
        }
    }
    return float3(sqrt(d1), sqrt(d2), id);
}

// MARK: - Carte de couverture

inline float rn_fieldAt(device const float *field, int count, int cols, int x, int y) {
    int i = y * cols + x;
    return (i >= 0 && i < count) ? field[i] : 1.0;
}

/// Poids de la B-spline cubique : courbe continue, sans les marches d'escalier du bilinéaire.
inline float4 rn_bsplineWeights(float t) {
    float t2 = t * t, t3 = t2 * t;
    return float4((1.0 - t) * (1.0 - t) * (1.0 - t),
                  3.0 * t3 - 6.0 * t2 + 4.0,
                  -3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0,
                  t3) / 6.0;
}

/// Couverture (1 = couvert) en `uv` normalisé, interpolation B-spline bicubique (16 lectures).
inline float rn_coverage(float2 uv, device const float *field, int count, float2 size) {
    int cols = int(size.x), rows = int(size.y);
    float x = clamp(uv.x * size.x - 0.5, 0.0, size.x - 1.0);
    float y = clamp(uv.y * size.y - 0.5, 0.0, size.y - 1.0);
    int x0 = int(x), y0 = int(y);
    float4 wx = rn_bsplineWeights(x - float(x0));
    float4 wy = rn_bsplineWeights(y - float(y0));
    float sum = 0.0;
    for (int j = 0; j < 4; j++) {
        int yy = clamp(y0 - 1 + j, 0, rows - 1);
        float row = 0.0;
        for (int i = 0; i < 4; i++) {
            int xx = clamp(x0 - 1 + i, 0, cols - 1);
            row += wx[i] * rn_fieldAt(field, count, cols, xx, yy);
        }
        sum += wy[j] * row;
    }
    return sum;
}

/// Couverture en un point en points (repère de la vue), à partir du rectangle de la vue.
inline float rn_coverageAt(float2 position, float4 rect, device const float *field, int count, float2 size) {
    return rn_coverage((position - rect.xy) / rect.zw, field, count, size);
}

#endif
