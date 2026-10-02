#include "RevealCommon.h"

// Ticket à gratter doré.
// La couche reçue est la peau (`GoldSkin`) : R = hauteur du relief, G = poli miroir, B = laque rouge.

/// Rampe de couleur de l'or, de l'ombre profonde à l'éclat blanc chaud.
inline float3 gold_ramp(float x) {
    x = clamp(x, 0.0, 1.3);
    const float3 c0 = float3(0.13, 0.065, 0.015);
    const float3 c1 = float3(0.42, 0.25, 0.065);
    const float3 c2 = float3(0.78, 0.56, 0.20);
    const float3 c3 = float3(0.96, 0.79, 0.42);
    const float3 c4 = float3(1.00, 0.93, 0.68);
    if (x < 0.25) return mix(c0, c1, x / 0.25);
    if (x < 0.55) return mix(c1, c2, (x - 0.25) / 0.30);
    if (x < 0.92) return mix(c2, c3, (x - 0.55) / 0.37);
    return mix(c3, c4, min(1.0, (x - 0.92) / 0.38));
}

/// Bruit de déchirure, fixe à l'écran, en points de déplacement du bord (≈ −1…1) : réseau de
/// fissures (F2 − F1 de Voronoï, nul sur les fissures) pour des éclats anguleux, grain fin pour les
/// micro-arrachements, ondulation lente. Continu : le bord reste antialiasable.
inline float gold_tear(float2 p) {
    float3 v = rn_voronoi(p * 0.3);
    float chip = clamp((v.y - v.x) * 1.5, 0.0, 1.0);
    float grain = rn_noise(p * 1.1);
    float wave = rn_noise(p * 0.07);
    return (chip - 0.55) * 1.9 + (grain - 0.5) * 0.5 + (wave - 0.5) * 2.4;
}

/// Éclats de la fin : gros morceaux (≈ 10 pt) qui se détachent les uns après les autres.
inline float gold_crumble(float2 p) {
    float3 v = rn_voronoi(p * 0.1);
    return (clamp((v.y - v.x) * 1.2, 0.0, 1.0) - 0.5) * 9.0 + (v.z - 0.5) * 6.0;
}

/// Déchirure du moment : fine pendant les gestes, en gros éclats pendant la fin (`dissolve` 0…1).
inline float gold_breakup(float2 p, float dissolve) {
    float tear = gold_tear(p);
    if (dissolve <= 0.0) return tear;
    return mix(tear, gold_crumble(p) + tear * 0.6, dissolve);
}

/// Bord de la feuille : x = distance signée en points (> 0 côté feuille), yz = normale du bord
/// tournée vers la photo. La distance au contour lisse (couverture = 0,5) est mesurée avec la pente
/// de la carte, puis la déchirure la décale d'une quantité fixe en points : le bord garde la même
/// finesse, que la carte descende d'un coup (grattage) ou en pente douce (souffle).
/// Pendant la fin, la feuille intacte est un plateau qui franchit 0,5 d'un bloc : une pente
/// plancher plus forte et de gros éclats l'effritent progressivement au lieu de l'effacer d'un coup.
inline float3 gold_edge(float2 pos, float4 rect, device const float *field, int count, float2 size, float dissolve) {
    float cov = rn_coverageAt(pos, rect, field, count, size);
    if (cov > 0.985) return float3(8.0, 0.0, -1.0);
    if (cov < 0.015) return float3(-8.0, 0.0, -1.0);

    const float h = 0.6;
    float cx = rn_coverageAt(pos + float2(h, 0.0), rect, field, count, size);
    float cy = rn_coverageAt(pos + float2(0.0, h), rect, field, count, size);
    float2 g = float2(cx - cov, cy - cov) / h;
    float gl = max(length(g), mix(0.012, 0.06, dissolve));
    float2 toFoil = length(g) > 1e-5 ? normalize(g) : float2(0.0, 1.0);
    float sd0 = (cov - 0.5) / gl;
    float reach = 6.0 + 9.0 * dissolve;
    if (abs(sd0) > reach) return float3(clamp(sd0, -8.0, 8.0), -toFoil);

    // Déchirure et sa pente, pour garder une distance juste (et donc un antialiasing d'un pixel).
    float t0 = gold_breakup(pos, dissolve);
    float tx = gold_breakup(pos + float2(0.5, 0.0), dissolve);
    float ty = gold_breakup(pos + float2(0.0, 0.5), dissolve);
    float2 grad = g / gl + float2(tx - t0, ty - t0) / 0.5;
    float len = max(length(grad), 0.25);
    return float3(clamp((sd0 + t0) / len, -8.0, 8.0), -grad / len);
}

[[ stitchable ]] half4 rnGold(float2 pos, SwiftUI::Layer layer, float4 rect,
                              device const float *field, int count, float2 size,
                              float time, float2 light, float dissolve) {
    float3 edge = gold_edge(pos, rect, field, count, size, dissolve);
    // Photo dégagée, loin de tout bord.
    if (edge.x <= -6.0) return half4(0.0);
    float sd = edge.x;
    float2 nh = edge.yz;

    // Lumière principale dans le plan : du haut-gauche vers le bas-droite.
    const float2 lightFlow = normalize(float2(0.45, 0.9));
    float away = max(0.0, dot(nh, lightFlow));

    // Ombre de la tranche du revêtement sur la photo, plus large à l'opposé de la lumière.
    float shadowWidth = 0.5 + 1.8 * away;
    float shadow = (1.0 - smoothstep(0.0, shadowWidth, -sd)) * (0.18 + 0.24 * away);
    float alpha = smoothstep(-0.2, 0.2, sd);
    if (alpha <= 0.001) {
        return half4(0.0, 0.0, 0.0, half(shadow));
    }

    // MARK: Relief de la peau
    half4 skin = layer.sample(pos);
    float polish = float(skin.g);
    float lacquer = float(skin.b);
    const float e = 0.75;
    float hl = float(layer.sample(pos - float2(e, 0.0)).r);
    float hr = float(layer.sample(pos + float2(e, 0.0)).r);
    float hu = float(layer.sample(pos - float2(0.0, e)).r);
    float hd = float(layer.sample(pos + float2(0.0, e)).r);
    float2 dh = float2(hr - hl, hd - hu) / (2.0 * e);
    float3 n = normalize(float3(-dh * 1.7, 1.0));

    // MARK: Brossage horizontal (atténué sur le poli)
    float matte = 1.0 - polish;
    float brush = rn_fbm(float2(pos.x * 0.011, pos.y * 0.85), 3);
    float brushFine = rn_noise(float2(pos.x * 0.045, pos.y * 2.3));
    float streak = (brush - 0.5) * 1.6 + (brushFine - 0.5) * 0.7;
    n = normalize(n + float3(0.0, streak * 0.07 * matte, 0.0));

    // MARK: Éclairage : œil à distance finie, lampe ponctuelle qui suit l'inclinaison
    float2 c = rect.xy + rect.zw * 0.5;
    float H = rect.w;
    float3 P = float3(pos - c, 0.0);
    float3 V = normalize(float3(0.0, 0.0, 2.4 * H) - P);
    float3 L = normalize(float3((light - 0.5) * rect.zw, 0.85 * H) - P);
    float3 Hv = normalize(L + V);
    float ndl = max(dot(n, L), 0.0);
    float ndh = max(dot(n, Hv), 0.0);

    // Reflet large + pic, plus serré et plus vif sur le poli.
    float spec = pow(ndh, mix(110.0, 420.0, polish)) * mix(0.42, 0.95, polish) * (0.55 + 0.9 * brush * matte + 0.45 * polish)
        + pow(ndh, 12.0) * 0.11;
    // Anisotropie (Kajiya-Kay) : les stries horizontales étirent le reflet en travers.
    float tdh = Hv.x;
    float aniso = pow(sqrt(max(0.0, 1.0 - tdh * tdh)), 140.0) * pow(ndh, 3.0) * 0.5 * matte * (0.7 + 0.6 * brush);

    // Environnement de studio : bandes claires au plafond, décalées avec la lampe.
    float3 R = reflect(-V, n);
    float u = R.y * 1.1 + R.x * 0.4 - (light.y - 0.5) * 0.45 + (light.x - 0.5) * 0.18;
    float env = 0.5 + 0.5 * sin(u * 6.5 + 0.9);
    env = env * env;

    // Brossé : surtout diffus. Poli miroir : sombre hors reflet, éclatant quand il renvoie le studio.
    float shadeMatte = 0.28 + 0.42 * (ndl - 0.55) + 0.21 * env + aniso + streak * 0.045;
    float shadePolish = 0.08 + 0.30 * (ndl - 0.55) + 0.66 * smoothstep(0.3, 0.92, env);
    float shade = mix(shadeMatte, shadePolish, polish) + spec;
    float3 col = gold_ramp(shade);

    // Laque rouge des baies : vernis brillant sur fond rouge profond.
    float3 laq = float3(0.46, 0.025, 0.05) * (0.45 + 0.75 * ndl) + float3(1.0, 0.88, 0.82) * pow(ndh, 70.0) * 0.9;
    col = mix(col, laq, clamp(lacquer, 0.0, 1.0));

    // Paillettes de la feuille : de rares facettes, chacune s'allume pour une position de la lampe.
    float2 gcell = floor(pos / 1.35);
    float gh = rn_hash(gcell + 7.31);
    if (gh > 0.992) {
        float2 facet = rn_hash2(gcell + 1.7) * 6.2832;
        float glint = sin(facet.x + light.x * 11.0) * sin(facet.y + light.y * 9.0 + time * 0.6);
        float2 f = fract(pos / 1.35) - 0.5;
        float dotMask = 1.0 - smoothstep(0.12, 0.45, length(f));
        col += pow(max(0.0, glint), 18.0) * dotMask * matte * float3(1.0, 0.95, 0.78) * 0.8;
    }

    // MARK: Bord de la zone grattée
    // Liseré sombre (la tranche) puis petit biseau clair qui accroche la lumière.
    float2 toLight = -lightFlow;
    float facing = dot(nh, toLight);
    float wall = 1.0 - smoothstep(0.0, 0.42, sd);
    float bevel = smoothstep(0.28, 0.55, sd) * (1.0 - smoothstep(0.7, 1.4, sd));
    float3 bevelColor = gold_ramp(shade + 0.32 + 0.3 * max(0.0, facing));
    col = mix(col, bevelColor, bevel * clamp(0.35 + 0.6 * facing, 0.0, 0.9));
    col = mix(col, float3(0.24, 0.15, 0.05), wall * (0.72 - 0.15 * facing));

    float a = alpha + shadow * (1.0 - alpha);
    return half4(half3(col * alpha), half(a));
}
