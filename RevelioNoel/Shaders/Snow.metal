#include "RevealCommon.h"

/// Bord bruité de la neige : la couverture plus un bruit, comparés à un seuil.
inline float snow_level(float2 pos, float4 rect, device const float *field, int count, float2 size) {
    float cov = rn_coverageAt(pos, rect, field, count, size);
    float edge = rn_fbm(pos * 0.055, 3) - 0.5;
    return cov + edge * 0.42;
}

/// Neige accumulée : bosses éclairées, bord épais bleuté, paillettes, ombre portée sur la photo.
[[ stitchable ]] half4 rnSnow(float2 pos, half4 color, float4 rect,
                              device const float *field, int count, float2 size, float time) {
    float t = snow_level(pos, rect, field, count, size);
    float alpha = smoothstep(0.40, 0.50, t);

    // Ombre portée : la neige « au-dessus à gauche » assombrit la photo.
    float tShadow = snow_level(pos - float2(4.0, 6.0), rect, field, count, size);
    float shadow = smoothstep(0.40, 0.56, tShadow) * 0.38;

    if (alpha <= 0.001) {
        return half4(0.0, 0.0, 0.0, half(shadow));
    }

    // Relief : bosses larges + épaisseur qui monte depuis le bord.
    float thickness = smoothstep(0.40, 0.95, t);
    float2 q = pos * 0.022;
    float h0 = rn_fbm(q, 4);
    float hx = rn_fbm(q + float2(0.04, 0.0), 4);
    float hy = rn_fbm(q + float2(0.0, 0.04), 4);
    float3 n = normalize(float3((h0 - hx) * 14.0, (h0 - hy) * 14.0, 1.0));
    // Le bord de la congère tombe vers la photo : la normale penche vers l'extérieur.
    float3 lightDir = normalize(float3(-0.45, -0.65, 0.62));
    float diffuse = clamp(dot(n, lightDir), 0.0, 1.0);

    float3 lit = float3(0.975, 0.985, 1.0);
    float3 shade = float3(0.70, 0.78, 0.93);
    float3 col = mix(shade, lit, 0.45 + 0.55 * diffuse);
    col *= 0.95 + 0.05 * rn_fbm(pos * 0.18, 2);

    // Tranche de la congère : bleutée et plus sombre près du bord.
    float rim = 1.0 - smoothstep(0.42, 0.70, t);
    col = mix(col, float3(0.58, 0.68, 0.88), rim * 0.6);
    // Liseré clair tout au bord, comme une arête qui accroche la lumière.
    float crest = smoothstep(0.40, 0.46, t) * (1.0 - smoothstep(0.46, 0.55, t));
    col += crest * 0.12;

    // Paillettes qui scintillent, surtout là où la neige est épaisse.
    float2 cell = floor(pos / 3.0);
    float hs = rn_hash(cell);
    float sparkle = step(0.986, hs) * pow(max(0.0, sin(time * 2.6 + hs * 90.0)), 18.0);
    col += sparkle * thickness * 0.9;

    float a = alpha + shadow * (1.0 - alpha);
    return half4(half3(col * alpha), half(a));
}

/// Masque provisoire : aplat teinté, en attendant le vrai rendu.
[[ stitchable ]] half4 rnPlaceholder(float2 pos, half4 color, float4 rect,
                                     device const float *field, int count, float2 size, half4 tint) {
    float cov = rn_coverageAt(pos, rect, field, count, size);
    float t = cov + (rn_fbm(pos * 0.06, 3) - 0.5) * 0.25;
    float alpha = smoothstep(0.42, 0.55, t);
    return tint * half(alpha);
}
