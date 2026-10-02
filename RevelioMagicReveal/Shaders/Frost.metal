#include "RevealCommon.h"

// Givre sur une vitre.
//
// - `rnFrostCrystals` dessine une fois pour toutes le motif des cristaux (plumes de glace, petites
//   étoiles, grain, épaisseur) dans une texture : il peut être riche, il ne coûte rien à chaque image.
//   Canaux : R = cristaux, G = épaisseur du givre, B = grain des facettes.
// - À chaque image, deux couches superposées (pas d'effet imbriqué) :
//   1. `rnFrostMeniscus`, sur une copie de la photo nette : ménisque d'eau le long du bord, côté vitre
//      dégagée (réfraction de la photo, reflet, pied sombre), film humide et perles d'eau ; transparente
//      ailleurs, hormis le reflet de la vitre.
//   2. `rnFrostPane`, au-dessus, sur la photo floutée : verre dépoli, voile laiteux, cristaux en relief
//      éclairés selon l'inclinaison, paillettes, zone fondue au bord ; transparente sur la vitre dégagée.
//
// Le bord est le contour t = 0,5 de t = couverture + bruit cristallin + cristaux (le bord s'effiloche le
// long des plumes). Sa distance en points vient du gradient de la couverture : le liseré garde la même
// largeur quel que soit le geste.

constant float2 kFrostReference = float2(360.0, 480.0);
constant float kFrostThreshold = 0.5;
/// Amplitude du bruit de bord, en unités de couverture.
constant float kFrostNoiseAmp = 0.26;
/// Part des cristaux dans le bord : le bord s'effiloche le long des plumes.
constant float kFrostFray = 0.22;
/// Part de l'épaisseur : le givre épais (vers le cadre) résiste plus longtemps que le voile mince du centre.
constant float kFrostThickness = 0.16;
/// Pente typique du bruit de bord (par point) : évite une distance infinie là où la couverture est plate.
constant float kFrostNoiseSlope = 0.014;

// MARK: - Motif des cristaux (pré-calculé)

inline float frost_line(float dist, float width, float aa) {
    return 1.0 - smoothstep(width, width + aa, dist);
}

/// Une plume de glace : rachis, barbes alternées à 60° vers la pointe (croissance hexagonale),
/// barbules sur les barbes si `detail`. `d` : position relative au germe ; `len` : longueur du rachis.
inline float frost_plume(float2 d, float2 dir, float len, float key, float aa,
                         float pitch, float reachScale, float thick, bool detail) {
    float u = dot(d, dir);
    float v = dot(d, float2(-dir.y, dir.x));
    float av = abs(v);
    float maxReach = 0.42 * reachScale;
    if (u < -0.04 || u > len + 0.02 || av > maxReach) return 0.0;
    float along = saturate(u / len);
    float tip = 1.0 - smoothstep(0.72, 1.0, along);
    float base = smoothstep(-0.03, 0.005, u);

    // Rachis : s'affine vers la pointe.
    float spine = frost_line(av, 0.011 * thick * (1.0 - 0.55 * along), aa) * tip * base;

    // Barbes : lignes u − |v|·cot 60° = attache, décalées d'un côté à l'autre, espacement irrégulier.
    const float cot60 = 0.57735;
    const float sin60 = 0.86603;
    float side = v >= 0.0 ? 0.0 : 0.5;
    float u0 = u - av * cot60;
    float k = floor(u0 / pitch - side + 0.5);
    float rnd = rn_hash(float2(k * 2.0 + side * 2.0, key));
    float attach = (k + side + (rnd - 0.5) * 0.35) * pitch;
    float perp = (u0 - attach) * sin60;
    float a = av / sin60;
    // Profil de plume : barbes courtes à la base, longues au milieu, qui raccourcissent vers la pointe.
    float at = saturate(attach / len);
    float profile = pow(saturate(sin(3.14159 * (0.12 + 0.88 * at))), 0.6) * (1.0 - 0.35 * at);
    float reach = maxReach * profile * (0.25 + 0.75 * rnd * rnd + 0.2 * rnd);
    float tb = a / max(reach, 1e-3);
    float inside = (1.0 - smoothstep(0.7, 1.0, tb)) * step(0.0, attach) * step(attach, len);
    float wb = 0.0075 * thick * (1.0 - 0.6 * saturate(tb));
    float barb = frost_line(abs(perp), wb, aa) * inside;

    float sub = 0.0;
    if (detail && inside > 0.0) {
        // Barbules : la même croissance à 60°, en plus petit, de part et d'autre de chaque barbe.
        float ap = abs(perp);
        float a2 = a - ap * cot60;
        const float pitch2 = 0.017;
        float k2 = floor(a2 / pitch2 + 0.5);
        float rnd2 = rn_hash(float2(k2, rnd * 71.0 + key));
        float perp2 = (a2 - k2 * pitch2) * sin60;
        float reach2 = 0.07 * (1.0 - saturate(tb)) * (0.3 + 0.7 * rnd2);
        float in2 = step(0.0, k2) * step(k2 * pitch2, a) * (1.0 - smoothstep(0.6, 1.0, ap / max(reach2, 1e-4)));
        sub = frost_line(abs(perp2), wb * 0.8, aa) * in2 * inside;
    }

    // Halo : la glace diffuse un peu de lumière autour des arêtes.
    float halo = (1.0 - smoothstep(0.0, 0.03 * thick + aa * 3.0, min(abs(perp), av))) * inside * tip * 0.16;
    return max(max(spine, barb * (0.65 + 0.35 * rnd)), max(sub * 0.7, halo));
}

/// Champ de plumes sur une grille jittérée. Elles poussent du cadre vers l'intérieur, en suivant un
/// courant lent (les voisines se ressemblent), et s'additionnent là où elles se croisent.
inline float frost_plumes(float2 p, float cell, float key, float presence, bool detail) {
    float2 q = p / cell;
    float2 base = floor(q);
    float aa = 0.5 / cell;
    float acc = 0.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 c = base + float2(i, j);
            float2 h = rn_hash2(c + key);
            if (fract(h.x * 3.91 + h.y * 1.37) > presence) continue;
            float2 seed = c + 0.1 + h * 0.8;
            float2 sp = seed * cell;
            float2 inward = normalize(kFrostReference * 0.5 - sp + 1e-3);
            float angle = (rn_noise(sp * 0.011 + key) - 0.5) * 2.2 + (h.x - 0.5) * 0.7;
            float ca = cos(angle), sa = sin(angle);
            float2 dir = float2(inward.x * ca - inward.y * sa, inward.x * sa + inward.y * ca);
            float len = 0.6 + 0.36 * fract(h.x * 5.17 + h.y);
            float f = frost_plume(q - seed, dir, len, key + h.x * 97.0, aa, 0.042, 1.0, 1.0, detail);
            f *= 0.5 + 0.5 * fract(h.y * 13.7 + h.x);
            acc = 1.0 - (1.0 - acc) * (1.0 - f);
        }
    }
    return acc;
}

/// Petites étoiles dendritiques à six branches, posées çà et là sur la vitre.
inline float frost_stars(float2 p, float cell, float key, float presence) {
    float2 c = floor(p / cell);
    float2 h = rn_hash2(c + key);
    if (h.x > presence) return 0.0;
    float2 center = (c + 0.3 + 0.4 * rn_hash2(c + key + 7.0)) * cell;
    float radius = cell * (0.17 + 0.11 * h.y);
    float2 d = (p - center) / radius;
    if (dot(d, d) > 1.1) return 0.0;
    float theta0 = h.y * 6.2832;
    float sector = floor((atan2(d.y, d.x) - theta0) / 1.0472 + 0.5);
    float a = theta0 + sector * 1.0472;
    float2 dir = float2(cos(a), sin(a));
    float aa = 0.5 / radius;
    float f = frost_plume(d, dir, 0.95, key + sector + h.x * 31.0, aa, 0.24, 0.9, 5.0, false);
    // Petit cœur hexagonal.
    float core = 1.0 - smoothstep(0.06, 0.06 + aa, length(d));
    return max(f, core) * (0.55 + 0.45 * h.y);
}

/// Motif complet, en coordonnées d'une carte de référence de 360 × 480 points.
[[ stitchable ]] half4 rnFrostCrystals(float2 pos, half4 color, float4 rect) {
    float2 p = (pos - rect.xy) / rect.zw * kFrostReference;

    // Épaisseur : le givre s'épaissit vers le cadre et dans les coins, en nappes irrégulières.
    float2 m = min(p, kFrostReference - p);
    float nappe = rn_fbm(p * 0.011 + 7.3, 3);
    float frame = min(m.x, m.y) + (nappe - 0.5) * 95.0;
    float border = 1.0 - smoothstep(0.0, 118.0, frame);
    float corner = (1.0 - smoothstep(0.0, 150.0, m.x)) * (1.0 - smoothstep(0.0, 150.0, m.y));
    border = saturate(max(border, corner));

    // Les plumes ondulent : déformation lente du plan.
    float2 warp = float2(rn_fbm(p * 0.017, 3), rn_fbm(p * 0.017 + 31.7, 3)) - 0.5;
    float2 pw = p + warp * 18.0;

    float big = frost_plumes(pw, 92.0, 11.0, mix(0.55, 0.95, border), true);
    float mid = frost_plumes(pw + 41.0, 37.0, 37.0, mix(0.45, 0.85, border), false);
    // Petites étoiles : discrètes, sinon elles ressemblent à des astérisques imprimés.
    float star = frost_stars(p + warp * 4.0, 19.0, 53.0, mix(0.10, 0.04, border));

    float crystal = 1.0 - (1.0 - big * mix(0.45, 1.0, border))
                        * (1.0 - mid * mix(0.2, 0.75, border))
                        * (1.0 - star * 0.25);

    // Grain : facettes de givre (sucre), chacune un peu plus ou moins claire.
    float3 facets = rn_voronoi(p / 3.1 + 5.0);
    float grain = facets.z * 0.75 + rn_noise(p * 1.1) * 0.25;

    float density = saturate(0.22 + border * 0.72 + (nappe - 0.5) * 0.5 + crystal * 0.22);
    return half4(half(crystal), half(density), half(grain), 1.0);
}

// MARK: - Lecture du motif

constexpr sampler frostSampler(coord::normalized, address::clamp_to_edge, filter::linear);

inline float2 frost_uv(float2 pos, float4 rect) {
    return (pos - rect.xy) / rect.zw;
}

// MARK: - Bord

struct FrostEdge {
    /// Couverture lissée au pixel.
    float cov;
    /// Distance signée au seuil sans le bruit, en points (> 0 côté givre).
    float dCov;
    /// Décalage maximal que le bruit et les cristaux peuvent apporter à la distance, en points.
    float slack;
    float invSlope;
    /// Direction qui pointe vers le givre.
    float2 normal;
};

inline FrostEdge frost_edge(float2 pos, float4 rect, device const float *field, int count, float2 size) {
    const float e = 1.5;
    float c0 = rn_coverageAt(pos, rect, field, count, size);
    float cx = rn_coverageAt(pos + float2(e, 0.0), rect, field, count, size);
    float cy = rn_coverageAt(pos + float2(0.0, e), rect, field, count, size);
    float2 g = float2(cx - c0, cy - c0) / e;
    float gl = length(g);
    FrostEdge r;
    r.cov = c0;
    r.invSlope = rsqrt(gl * gl + kFrostNoiseSlope * kFrostNoiseSlope);
    r.dCov = (c0 - kFrostThreshold) * r.invSlope;
    r.slack = (kFrostNoiseAmp * 0.5 + kFrostFray * 0.8 + kFrostThickness * 0.5) * r.invSlope;
    r.normal = gl > 1e-5 ? g / gl : float2(0.0, -1.0);
    return r;
}

/// Bruit de bord (0…1) : ondulation, facettes de Voronoï aux frontières droites (aspect cristallin), grain.
/// Plus le bord est humide, plus les facettes fondent.
inline float frost_edgeNoise(float2 pos, float wetness) {
    float wave = rn_fbm(pos * 0.05, 2);
    float3 v = rn_voronoi(pos * 0.21 + 3.1);
    float facet = clamp((v.y - v.x) * 1.7, 0.0, 1.0);
    float grain = rn_noise(pos * 1.1);
    float facetWeight = 0.4 * (1.0 - 0.5 * wetness);
    return (wave * 0.45 + facet * facetWeight + grain * 0.15) / (0.6 + facetWeight) ;
}

/// Distance signée au bord, en points (> 0 côté givre). `crystal`, `density` : valeurs du motif au pixel.
inline float frost_distance(FrostEdge e, float2 pos, float crystal, float density, float wetness) {
    float shift = kFrostNoiseAmp * (frost_edgeNoise(pos, wetness) - 0.5) + kFrostFray * (crystal - 0.3)
                + kFrostThickness * (density - 0.5);
    return e.dCov + shift * e.invSlope;
}

/// Direction de la lumière dans le plan de l'écran : vient d'en haut (opposé à la gravité), un peu de la gauche.
inline float2 frost_toLight(float2 gravity) {
    return normalize(float2(-0.35, 0.0) - gravity);
}

/// Reflet de la vitre : deux bandes diagonales qui glissent avec l'inclinaison. Rend l'opacité d'un voile blanc.
inline float frost_sheen(float2 pos, float4 rect, float2 gravity) {
    float2 uv = frost_uv(pos, rect);
    float s = uv.x * 0.8 + uv.y * 0.6 + gravity.x * 0.2;
    float wide = exp(-pow((s - 0.52) / 0.11, 2.0)) * 0.045;
    float thin = exp(-pow((s - 0.76) / 0.022, 2.0)) * 0.035;
    return wide + thin;
}

// MARK: - Paillettes

/// Facettes de glace orientées qui renvoient la lumière selon l'inclinaison (et doucement avec le temps).
inline float frost_glitter(float2 pos, float2 toLight, float time) {
    float la = atan2(toLight.y, toLight.x);
    float result = 0.0;

    // Gros éclats : une cellule de 5 pt sur quinze porte une facette, avec une croix de diffraction.
    float2 cell = floor(pos / 5.0);
    float h = rn_hash(cell + 0.37);
    if (h > 0.935) {
        float2 o = cell * 5.0 + 1.4 + rn_hash2(cell + 9.1) * 2.2;
        float2 r = pos - o;
        float facet = fract(h * 37.0) * 6.2832;
        float lit = pow(max(0.0, cos(facet - la * 3.0 - time * 0.35)), 40.0);
        float twinkle = 0.7 + 0.3 * sin(time * 9.0 + h * 210.0);
        float core = exp(-dot(r, r) * 2.2);
        float2 ar = abs(r);
        float arms = (exp(-ar.y * 7.0 - ar.x * 1.4) + exp(-ar.x * 7.0 - ar.y * 1.4)) * (1.0 - smoothstep(1.4, 2.4, length(r)));
        result += lit * twinkle * (core * 1.7 + arms * 0.75);
    }

    // Grain scintillant : petits points qui s'allument quand on incline.
    float2 fine = floor(pos / 1.7);
    float hf = rn_hash(fine + 5.3);
    if (hf > 0.88) {
        float2 r = pos - (fine + 0.5) * 1.7;
        float lit = pow(max(0.0, cos(hf * 91.0 - la * 4.0 - time * 0.5)), 24.0);
        result += lit * exp(-dot(r, r) * 5.0) * 0.45;
    }
    return result;
}

// MARK: - Couche du givre

/// `layer` : la photo floutée. `crystals` : le motif pré-calculé.
/// `wetness` (0…1) : bord sec et cassant (secouer) → fondu et humide (souffler).
[[ stitchable ]] half4 rnFrostPane(float2 pos, SwiftUI::Layer layer, float4 rect,
                                   device const float *field, int count, float2 size,
                                   texture2d<half> crystals, float time, float2 gravity, float wetness) {
    FrostEdge e = frost_edge(pos, rect, field, count, size);
    float meltWidth = mix(3.0, 11.0, wetness);
    if (e.dCov + e.slack < -0.6) return half4(0.0);

    float2 uv = frost_uv(pos, rect);
    half4 motif = crystals.sample(frostSampler, uv);
    float crystal = float(motif.r);
    float density = float(motif.g);
    float grain = float(motif.b);

    // Plein givre loin du bord : inutile d'évaluer le bruit.
    float d = (e.dCov - e.slack > meltWidth + 2.0) ? 1000.0 : frost_distance(e, pos, crystal, density, wetness);
    float alpha = smoothstep(-0.45, 0.45, d);
    if (alpha <= 0.0) return half4(0.0);

    float2 toLight = frost_toLight(gravity);

    // Zone fondue au bord, et givre aminci là où la couverture a seulement baissé.
    float wet = (1.0 - smoothstep(0.0, meltWidth, d)) * wetness;

    // Verre dépoli : chaque pixel lit la photo floutée un peu à côté (grain de diffusion) ;
    // dans la zone fondue, l'eau fait lentille et décale l'image vers le bord.
    float2 jitter = (rn_hash2(floor(pos * 3.0)) - 0.5) * 2.4 * (1.0 - 0.6 * wet);
    float2 lens = -e.normal * wet * (1.0 - wet) * 6.0;
    float3 photo = float3(layer.sample(pos + jitter + lens).rgb);
    float lum = dot(photo, float3(0.299, 0.587, 0.114));
    photo = mix(float3(lum), photo, 0.85);
    float thin = smoothstep(0.5, 0.97, e.cov);

    // Voile laiteux : mince au centre (on devine les lumières), épais vers le cadre.
    float veil = mix(0.46, 0.93, density) * mix(0.5, 1.0, thin) * (1.0 - wet * 0.55);
    float3 milk = float3(0.90, 0.935, 0.975);
    float3 col = mix(photo, milk, saturate(veil));
    // La lumière diffusée éclaircit un peu ce qu'on voit à travers.
    col = 1.0 - (1.0 - col) * (1.0 - 0.06 * (1.0 - veil));

    // Facettes du givre (sucre) : légère variation de clarté.
    col *= 1.0 + (grain - 0.5) * 0.07 * density;

    // Cristaux en relief, éclairés selon l'inclinaison du téléphone.
    float2 px = 0.7 / rect.zw;
    float cx = float(crystals.sample(frostSampler, uv + float2(px.x, 0.0)).r);
    float cy = float(crystals.sample(frostSampler, uv + float2(0.0, px.y)).r);
    float2 slope = float2(cx - crystal, cy - crystal);
    float relief = dot(slope, -toLight) * 1.6;
    float ice = crystal * (1.0 - wet) * mix(0.35, 1.0, thin);
    col = mix(col, float3(0.985, 0.992, 1.0), ice * 0.8);
    // La glace est translucide : arêtes claires côté lumière, ombre à peine bleutée de l'autre.
    col += saturate(relief) * ice * float3(0.9, 0.95, 1.0);
    col *= mix(float3(1.0), float3(0.94, 0.965, 1.0), saturate(-relief * 2.0) * ice);

    // Fondu : la glace devient de l'eau, plus sombre et translucide.
    col = mix(col, col * float3(0.84, 0.88, 0.93), wet * 0.85);
    // Arête du givre qui accroche la lumière.
    float rim = smoothstep(0.0, 0.5, d) * (1.0 - smoothstep(0.6, 2.0, d));
    col += rim * mix(0.16, 0.07, wetness);

    float glitter = frost_glitter(pos, toLight, time);
    col += glitter * (0.3 + 0.7 * saturate(crystal * 1.5)) * (0.4 + 0.6 * density) * (1.0 - wet) * thin;
    col = saturate(col);
    col += (1.0 - col) * frost_sheen(pos, rect, gravity);

    return half4(half3(col * alpha), half(alpha));
}

// MARK: - Couche du ménisque

/// `layer` : la photo nette. Ne dessine que le bord humide côté vitre dégagée (et le reflet de la vitre) :
/// le givre est posé par-dessus.
[[ stitchable ]] half4 rnFrostMeniscus(float2 pos, SwiftUI::Layer layer, float4 rect,
                                       device const float *field, int count, float2 size,
                                       texture2d<half> crystals, float time, float2 gravity, float wetness) {
    FrostEdge e = frost_edge(pos, rect, field, count, size);
    float filmWidth = mix(5.0, 16.0, wetness);
    if (e.dCov - e.slack > 0.6) return half4(0.0);
    if (e.dCov + e.slack < -(filmWidth + 1.0)) return half4(half(frost_sheen(pos, rect, gravity)));

    half4 motif = crystals.sample(frostSampler, frost_uv(pos, rect));
    float d = frost_distance(e, pos, float(motif.r), float(motif.g), wetness);
    float coverage = 1.0 - smoothstep(-0.45, 0.45, d);
    if (coverage <= 0.0) return half4(0.0);
    float2 toward = e.normal;
    float2 toLight = frost_toLight(gravity);

    // Ménisque : l'eau remonte contre le givre sur quelques points, côté vitre dégagée.
    float menWidth = mix(1.6, 3.4, wetness) * (0.75 + 0.5 * rn_noise(pos * 0.07));
    float s = saturate(-d / menWidth);
    float onMeniscus = step(d, 0.0) * step(s, 0.999);
    float slope = onMeniscus * 2.0 * (1.0 - s);
    float2 offset = -toward * slope * menWidth * 0.55;

    // Perles d'eau sur le film humide : petites lentilles qui retournent l'image.
    float filmT = saturate((-d - menWidth) / max(filmWidth - menWidth, 0.1));
    float bead = 0.0;
    float2 beadUV = float2(0.0);
    if (d < -menWidth * 0.8 && filmT < 1.0) {
        const float cell = 5.0;
        float2 cid = floor(pos / cell);
        float2 h = rn_hash2(cid + 17.0);
        float presence = (1.0 - filmT) * (1.0 - filmT) * 0.8 * wetness;
        if (h.x < presence) {
            float radius = cell * (0.13 + 0.19 * h.y);
            float2 center = (cid + 0.5 + (rn_hash2(cid + 3.0) - 0.5) * (1.0 - 2.4 * radius / cell)) * cell;
            float2 r = pos - center;
            float len = length(r);
            bead = 1.0 - smoothstep(radius - 0.4, radius, len);
            beadUV = r / radius;
            offset = mix(offset, -r * 2.6, bead);
        }
    }

    float3 col = float3(layer.sample(pos + offset).rgb);

    if (d < 0.0) {
        // Film humide : la photo est un peu plus sombre sous l'eau.
        float film = 1.0 - smoothstep(menWidth, filmWidth, -d);
        col *= 1.0 - 0.09 * film * wetness;

        // Pied du ménisque : fine ligne sombre là où l'eau rejoint le verre.
        float footX = (-d - menWidth * 0.9) / 0.5;
        col *= 1.0 - 0.30 * exp(-footX * footX);

        // Reflet spéculaire près du givre, plus vif sur les bords tournés vers la lumière.
        float facing = saturate(dot(-toward, toLight));
        float specX = (-d - menWidth * 0.3) / 0.42;
        float spec = exp(-specX * specX) * (0.14 + 0.62 * facing * facing);
        col += (1.0 - col) * spec;
    }

    if (bead > 0.0) {
        float rr = length(beadUV);
        float rim = smoothstep(0.55, 1.0, rr);
        float3 shaded = col * (1.0 - 0.45 * rim);
        // Reflet côté lumière, caustique (lumière concentrée) du côté opposé.
        float2 hl = beadUV - toLight * 0.42;
        shaded += exp(-dot(hl, hl) * 22.0) * 0.75;
        float2 caustic = beadUV + toLight * 0.45;
        shaded += exp(-dot(caustic, caustic) * 14.0) * 0.18;
        col = mix(col, shaded, bead);
    }

    col = saturate(col);
    col += (1.0 - col) * frost_sheen(pos, rect, gravity);
    return half4(half3(col * coverage), half(coverage));
}
