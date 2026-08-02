//
//  CardSurface.metal
//  binderBuilder
//
//  CustomMaterial SURFACE shader for the card front (no geometry modifier).
//  Composites: base art -> a per-rarity foil accent -> grayscale LAST for
//  unowned cards.
//
//  The foil is chosen by a FOIL TIER (FoilTier.swift), so a base-set holo
//  sparkles only inside its art window, a reverse holo sparkles everywhere
//  BUT the window, a full-art ultra rare shows an etched relief highlight,
//  a secret rare sweeps rainbow bands, and the gold tiers collapse those
//  bands to amber. Each branch is a different *pattern*, not a different
//  amplitude — see the cap discipline below.
//
//  Uniforms in custom_parameter(), packed by FoilUniforms (RealityKit gives a
//  CustomMaterial exactly one float4 + one texture, and .zw are spoken for by
//  MotionUpdateSystem, so the tier and the art-box era ride in the integer
//  parts of .x/.y):
//
//    .x = float(tierCode) + holoStrength     (strength is < 1 by construction)
//    .y = float(artBoxEra) * 2 + grayscaleAmount
//    .zw = light phase (hue offsets driven by device tilt)
//

#include <metal_stdlib>
#include <RealityKit/RealityKit.h>

using namespace metal;

// Tier codes — must match FoilTier.rawValue in FoilTier.swift.
constant int BB_TIER_NONE      = 0;
constant int BB_TIER_HOLO_ART  = 1;
constant int BB_TIER_REVERSE   = 2;
constant int BB_TIER_ETCHED    = 3;
constant int BB_TIER_IR        = 4;
constant int BB_TIER_SIR       = 5;
constant int BB_TIER_RAINBOW   = 6;
constant int BB_TIER_GOLD      = 7;
constant int BB_TIER_MEGA_GOLD = 8;

static inline float2 bb_hash22(float2 p)
{
    const float2 q = float2(dot(p, float2(127.1f, 311.7f)),
                            dot(p, float2(269.5f, 183.3f)));
    return fract(sin(q) * 43758.5453f);
}

/// Cheap hue -> RGB ramp (HSV with s = v = 1).
static inline float3 bb_card_hue_ramp(float hue)
{
    const float3 t = abs(fract(float3(hue) + float3(1.0f, 2.0f / 3.0f, 1.0f / 3.0f)) * 6.0f - 3.0f) - 1.0f;
    return clamp(t, 0.0f, 1.0f);
}

static inline float bb_card_luminance(float3 c)
{
    return dot(c, float3(0.2126f, 0.7152f, 0.0722f));
}

/// Signed distance to a rounded box centered on the origin (uv space).
static inline float bb_rounded_box_sdf(float2 p, float2 halfSize, float radius)
{
    const float2 q = abs(p) - (halfSize - radius);
    return length(max(q, 0.0f)) + min(max(q.x, q.y), 0.0f) - radius;
}

/// Soft mask over the card's illustration window. uv.y runs 0 (top) -> 1
/// (bottom) after the flip below.
///
/// CALIBRATION: the two rectangles are the industry-standard frame
/// proportions, not per-set measurements — the classic vertical frame (base
/// set through Sword & Shield) puts the window at y in [0.13, 0.56], and the
/// Scarlet & Violet frame sits slightly higher/smaller. Treat both as tunable
/// constants; era selection comes from the uniform, not from the texture.
static inline float bb_art_box(float2 uv, int era)
{
    const float2 lo = (era == 0) ? float2(0.080f, 0.130f) : float2(0.070f, 0.100f);
    const float2 hi = (era == 0) ? float2(0.920f, 0.560f) : float2(0.930f, 0.530f);
    const float2 center = 0.5f * (lo + hi);
    const float2 halfExtent = 0.5f * (hi - lo);
    const float d = bb_rounded_box_sdf(uv - center, halfExtent, 0.035f);
    // Smoothstepped, not binary, so the foil fades at the frame edge instead
    // of showing a seam.
    return 1.0f - smoothstep(-0.025f, 0.025f, d);
}

/// Voronoi sparkle field: nearest-seed falloff over a jittered grid, with a
/// per-cell twinkle phase so the flecks do NOT all catch light at once (the
/// thing that separates real foil from a flat glitter layer).
static inline float bb_spark(float2 uv, float2 density, float radius, float2 phase, float twinkle)
{
    const float2 p = uv * density;
    const float2 cellID = floor(p);
    const float2 f = fract(p);

    float best = 1e9f;
    float seedRand = 0.0f;
    for (int j = -1; j <= 1; ++j) {
        for (int i = -1; i <= 1; ++i) {
            const float2 g = float2(float(i), float(j));
            const float2 h = bb_hash22(cellID + g);
            const float2 toSeed = g + h - f;
            const float d2 = dot(toSeed, toSeed);
            if (d2 < best) {
                best = d2;
                seedRand = h.x + 1.37f * h.y;
            }
        }
    }
    const float spark = smoothstep(radius, 0.0f, sqrt(best));
    // Each fleck lights at its own tilt angle.
    const float tw = 0.5f + 0.5f * sin(seedRand * 21.7f + phase.x * 6.2831f + phase.y * 4.1f);
    return spark * mix(1.0f - twinkle, 1.0f, tw);
}

/// Position along a *rotating* axis: real diffraction foil rotates its band
/// angle with view direction, it does not merely recolor in place.
static inline float bb_band_coord(float2 uv, float2 phase)
{
    const float angle = phase.x * 1.35f + phase.y * 2.10f;
    const float2 axis = float2(cos(angle), sin(angle));
    return dot(uv - 0.5f, axis) + phase.x * 0.30f;
}

/// Etch heightfield: concentric rings crossed with a brushed diagonal. Generic
/// on purpose — the point is the *feel* of embossed relief, and reproducing a
/// printed foil pattern is not on the table.
static inline float bb_etch_height(float2 uv)
{
    const float2 d = uv - float2(0.5f, 0.42f);
    const float rings = sin(length(d * float2(1.0f, 1.35f)) * 58.0f);
    const float lines = sin(dot(uv, float2(0.86f, 0.51f)) * 155.0f);
    return 0.62f * rings + 0.38f * lines;
}

/// Hard ceiling on the additive foil term. The holo is folded into the
/// *base color* (albedo), which the lighting integrator then multiplies by the
/// scene illuminance — so an unbounded term does not "glow", it multiplies.
/// Capping it keeps albedo physical (<= 1 after the add) and guarantees the
/// card art stays readable no matter how hot the rig or how strong the foil.
///
/// EVERY tier branch below funnels through this cap: each one produces a
/// bounded [0,1]-ish accent, scales it by holoStrength * mask, and is then
/// min()'d per channel. Nothing is allowed to run away.
constant float bb_holo_cap = 0.42f;

/// Warm foil hue for the gold tiers (amber, ~hue 0.10).
constant float3 bb_gold = float3(1.00f, 0.80f, 0.36f);

[[visible]]
void cardSurface(realitykit::surface_parameters params)
{
    constexpr sampler bilinear(filter::linear, mip_filter::linear, address::clamp_to_edge);

    float2 uv = params.geometry().uv0();
    // RealityKit texture coordinates are flipped vertically relative to
    // MeshDescriptor UVs — flip to match PhysicallyBasedMaterial's convention.
    // After this, uv.y = 0 is the TOP of the card (where the art window is).
    uv.y = 1.0f - uv.y;

    const float4 u = params.uniforms().custom_parameter();

    // Unpack (see the header note; twin of FoilUniforms in FoilTier.swift).
    const float tierF = floor(u.x);
    // max(): a garbage/uninitialised uniform falls into the flat branch rather
    // than indexing off the bottom of the tier space.
    const int tier = max(int(tierF), BB_TIER_NONE);
    const float holoStrength = u.x - tierF;
    const float eraF = floor(u.y * 0.5f);
    const int era = int(eraF);
    const float grayscaleAmount = saturate(u.y - eraF * 2.0f);
    const float2 lightPhase = u.zw;

    const half3 tint = (half3)params.material_constants().base_color_tint().rgb;
    const half4 baseSample = params.textures().base_color().sample(bilinear, uv);
    float3 color = float3(baseSample.rgb * tint);

    // Fresnel rim response from world-space normal vs view direction.
    const float3 N = normalize(params.geometry().normal());
    float3 V = normalize(params.geometry().view_direction());
    // Defensive: the specular lobe below needs V pointing back at the camera.
    if (dot(N, V) < 0.0f) { V = -V; }
    const float ndv = saturate(dot(N, V));
    const float fresnel = powr(1.0f - ndv, 2.0f);

    // NB there is deliberately NO texture-slot mask here any more. The original
    // shader gated the whole holo term on
    // `params.textures().custom().sample(...).r`, on the assumption that an
    // unbound custom texture reads as flat 1x1 white. It does not — RealityKit
    // hands an unbound custom slot back as BLACK, and nothing ever bound one,
    // so that factor was a constant 0 and the foil has been multiplied out of
    // existence since it was written (verified on-device by dumping the sampled
    // value to base_color: solid 0 in the green channel on every card). The
    // masking this shader actually needs is per-tier and geometric, so it is
    // computed procedurally by bb_art_box() inside the branches below.

    // Shared iridescent hue: sweeps with view direction (against a stable
    // horizontal tangent), the motion-driven light phase, and a diagonal
    // across the card. The phase carries HUE OFFSETS only — never amplitude.
    float3 tangent = cross(float3(0.0f, 1.0f, 0.0f), N);
    tangent = (length_squared(tangent) < 1e-5f) ? float3(1.0f, 0.0f, 0.0f) : normalize(tangent);
    const float hue = fract(1.7f * dot(V, tangent)
                            + lightPhase.x
                            + 0.45f * lightPhase.y
                            + uv.x * 1.25f
                            + uv.y * 0.35f);
    const float3 rainbow = bb_card_hue_ramp(hue);

    // Rim band in uv space, for the restrained "foil border" tiers.
    const float2 edgeDist = min(uv, 1.0f - uv);
    const float rim = 1.0f - smoothstep(0.0f, 0.110f, min(edgeDist.x, edgeDist.y));

    // ---- Per-tier accent. ----
    //
    // EXPOSURE BUDGET (commit 533b08e discipline). `accent` is NOT a 0..1
    // pattern that something else scales down later — it is already in units of
    // *albedo added to the print*, so every branch has to hold itself to:
    //
    //   * broad/flat term (the part covering most of the face)  <= ~0.10
    //   * peak patterned term (sparkle cores, band crests)      <= ~0.35
    //
    // holoStrength (<= 0.99) then trims it and bb_holo_cap is the hard ceiling.
    // The 0.15-0.35 accent range is what keeps the printed art legible: a foil
    // you can read a card through. Numbers above that flood the whole face to
    // white/amber — which is exactly what the first pass did once the dead
    // texture mask stopped zeroing this term.
    float3 accent = float3(0.0f);
    float roughness = 0.42f;
    // White broadband reflectance. Right for a print under a clear laminate,
    // which is every tier but one — see the mega note below.
    float specular = 0.50f;

    if (tier == BB_TIER_HOLO_ART) {
        // Classic holo: cosmos dot-field confined to the art window.
        const float art = bb_art_box(uv, era);
        const float big = bb_spark(uv, float2(15.0f, 21.0f), 0.36f, lightPhase, 0.75f);
        const float fine = bb_spark(uv, float2(38.0f, 53.0f), 0.26f, lightPhase * 1.7f, 0.85f);
        const float dots = saturate(0.75f * big + 0.55f * fine);
        const float3 fleck = mix(float3(1.0f), rainbow, 0.60f);
        accent = art * saturate(fleck * dots * 0.36f
                                + rainbow * (0.030f + 0.075f * fresnel));
        roughness = 0.38f;
    } else if (tier == BB_TIER_REVERSE) {
        // Reverse holo: fine pixel/lattice sparkle on the frame + text boxes,
        // art window deliberately matte.
        const float inv = 1.0f - bb_art_box(uv, era);
        const float fine = bb_spark(uv, float2(62.0f, 86.0f), 0.24f, lightPhase, 0.70f);
        const float3 fleck = mix(float3(1.0f), rainbow, 0.40f);
        accent = inv * saturate(fleck * fine * 0.46f
                                + rainbow * (0.022f + 0.060f * fresnel));
        roughness = 0.40f;
    } else if (tier == BB_TIER_ETCHED) {
        // Full-art ultra rare: procedural etch, lit so the embossed relief only
        // APPEARS where its slope faces a key that swings with tilt.
        //
        // This is the normal-perturbation model evaluated IN THE TANGENT FRAME
        // rather than in world space. Perturbing N by the heightfield gradient
        // and taking a world-space specular lobe (N' . H)^k is the textbook
        // form, but on a flat quad `dot(N, H)` is very nearly constant across
        // the whole card: the relief then either floods or — far more often —
        // never fires at all, which is what the first pass did (the etch tier
        // measured a max delta of 34/255, essentially just its ambient wash).
        // For a plane, N' . L expands to (N . L) - bump * (grad h . L_tangent),
        // so projecting the gradient straight onto an in-plane key direction is
        // the same signal with the card's absolute pose divided out.
        const float eps = 0.0025f;
        const float h0 = bb_etch_height(uv);
        const float dHdx = (bb_etch_height(uv + float2(eps, 0.0f)) - h0) / eps;
        const float dHdy = (bb_etch_height(uv + float2(0.0f, eps)) - h0) / eps;
        const float keyAngle = lightPhase.x * 1.9f + lightPhase.y * 1.1f;
        const float2 keyDir = float2(cos(keyAngle), sin(keyAngle));
        const float slope = clamp((dHdx * keyDir.x + dHdy * keyDir.y) * 0.011f, -1.0f, 1.0f);
        // Only crests turned toward the key light up; the rest stays matte.
        const float relief = powr(saturate(slope), 2.2f);
        // Broad envelope so the lit region sweeps across the face on tilt
        // instead of the whole engraving flashing at once.
        const float sweep = 0.40f + 0.60f
            * (0.5f + 0.5f * sin(bb_band_coord(uv, lightPhase) * 3.4f));
        const float3 sheen = mix(float3(1.0f, 0.97f, 0.90f), rainbow, 0.30f);
        accent = saturate(sheen * relief * sweep * 0.44f
                          + rainbow * (0.025f + 0.070f * fresnel));
        roughness = 0.34f;
    } else if (tier == BB_TIER_IR) {
        // Illustration rare: restrained — a soft sheen border plus a sparse
        // fleck or two, deliberately an order of magnitude thinner than the SIR
        // glitter below (real IRs are alt-art with foil only on the accents).
        const float3 sheen = mix(float3(1.0f), rainbow, 0.55f);
        const float fleck = bb_spark(uv, float2(26.0f, 36.0f), 0.16f, lightPhase, 0.85f);
        accent = saturate(sheen * rim * (0.16f + 0.34f * fresnel)
                          + sheen * fleck * 0.15f
                          + rainbow * (0.018f + 0.045f * fresnel));
        roughness = 0.38f;
    } else if (tier == BB_TIER_SIR) {
        // Special illustration rare: dense full-face glitter + fresnel rim.
        const float glitter = bb_spark(uv, float2(34.0f, 47.0f), 0.32f, lightPhase, 0.80f);
        const float fine = bb_spark(uv, float2(78.0f, 108.0f), 0.20f, lightPhase * 2.3f, 0.90f);
        const float3 fleck = mix(float3(1.0f), rainbow, 0.45f);
        accent = saturate(fleck * saturate(glitter + 0.5f * fine) * 0.38f
                          + rainbow * (0.030f + 0.080f * fresnel)
                          + rim * 0.10f * fresnel);
        roughness = 0.34f;
    } else if (tier == BB_TIER_RAINBOW) {
        // Rainbow / secret rare: broad angular bands over the whole face, band
        // ANGLE rotating with tilt. The contrast between crest and trough (not
        // the absolute level) is what reads as a diffraction sweep.
        const float band = bb_band_coord(uv, lightPhase);
        const float3 bands = bb_card_hue_ramp(fract(band * 2.4f + lightPhase.x * 0.6f));
        // Low ridge frequency on purpose: a real rainbow rare shows a handful
        // of BROAD sweeps, and anything fine enough to alias just averages out
        // to a flat wash at pocket size.
        const float ridge = 0.20f + 0.80f * (0.5f + 0.5f * sin(band * 9.0f + lightPhase.x * 5.0f));
        accent = saturate(bands * ridge * (0.10f + 0.22f * fresnel));
        roughness = 0.32f;
    } else if (tier == BB_TIER_GOLD || tier == BB_TIER_MEGA_GOLD) {
        // Gold tiers: the same rotating bands, saturation collapsed into the
        // amber range, plus a strong fresnel catch. Mega stays fully
        // monochrome and sparkles finer and denser.
        //
        // MEGA IS BUDGETED SEPARATELY, and not because it wants to be quieter.
        // It is the one tier whose PRINT is already gold: me02-130 measures a
        // mean sRGB of (0.90, 0.74, 0.05), a gold-on-gold face whose artwork is
        // carried entirely by shallow relief. Two things then break under the
        // goldHyper numbers, which is why that tier can wear them and this one
        // cannot:
        //
        //   * `accent` is added to LINEAR albedo. This print's blue sits at
        //     ~0.004 linear, so a broad gold term of ~0.2 re-encodes to a blue
        //     of ~0.45 for display — a 100x lift that turns amber into pale
        //     yellow all by itself.
        //   * its red is already ~0.78 linear, so the same add clips. Measured
        //     on the reported screenshot: 90% of the card's pixels sat at
        //     R > 0.98 and luminance contrast fell from the print's 0.119 to
        //     0.074.
        //
        // Clipped highlights over a floor lifted 100x is precisely the reported
        // "flat yellow with a ghost silhouette". So mega keeps its identity in
        // PATTERN — monochrome gold, finer/denser sparkle, warm fresnel — and
        // holds its BROAD terms to the documented <= 0.10, scaled further by
        // whatever headroom the print itself leaves.
        const bool mega = (tier == BB_TIER_MEGA_GOLD);
        const float band = bb_band_coord(uv, lightPhase);
        const float ridge = 0.18f + 0.82f
            * (0.5f + 0.5f * sin(band * (mega ? 16.0f : 11.0f) + lightPhase.x * 4.5f));
        // Hyper rare keeps a hint of spectrum in the gold; mega does not.
        const float3 hueTint = mega
            ? bb_gold
            : mix(bb_gold, bb_card_hue_ramp(fract(0.09f + 0.10f * sin(band * 6.0f + lightPhase.x))), 0.30f);
        // Denser than goldHyper, but with tighter cores: at pocket size a wide
        // core stops resolving as flecks and just averages into another broad
        // wash, which is the other half of why mega read flat in the binder.
        const float2 density = mega ? float2(58.0f, 80.0f) : float2(30.0f, 42.0f);
        const float grain = bb_spark(uv, density, mega ? 0.20f : 0.26f, lightPhase, 0.80f);
        // Room left before the add clips: 1 on dark art, ~0.35 on a gold face.
        // Broad terms only — sparkle CORES are supposed to reach white, that is
        // what makes a fleck a fleck.
        const float headroom = mega ? saturate(1.0f - bb_card_luminance(color)) : 1.0f;
        const float broadAmp = mega ? (0.035f + 0.075f * fresnel)
                                    : (0.085f + 0.185f * fresnel);
        accent = saturate(hueTint * ridge * broadAmp * headroom
                          + bb_gold * grain * (mega ? 0.30f : 0.26f)
                          + bb_gold * rim * (mega ? 0.10f : 0.12f) * fresnel * headroom);
        roughness = mega ? 0.28f : 0.30f;
        if (mega) {
            // The other half of the bleaching, and the half no accent budget
            // could have reached: a 0.5 WHITE specular over an already-gold
            // print. Every other tier has a colourful print underneath, so a
            // white environment reflection just reads as gloss; on gold-on-gold
            // it is a broad white veil laid over the one hue the card has, and
            // it measured bigger than the foil term itself (zeroing the whole
            // mega accent moved the card's contrast by 0.006, dropping this to
            // 0.22 moved it by 0.014 and pulled blue down from 0.47 to 0.36).
            // Gold leaf reflects GOLD, not white, so the low value is also the
            // physically honest one; the tier's warmth now comes from the print
            // and the fresnel/grain accent rather than from a white sheen.
            specular = 0.22f;
        }
    } else {
        // BB_TIER_NONE (and any future/unknown code): a whisper of sheen, the
        // same "printed card catches the light" the flat tiers had before.
        accent = saturate(rainbow * fresnel * 0.45f);
    }

    // Capped per channel: a full-strength foil at a grazing angle tops out at
    // bb_holo_cap of extra albedo instead of running away (which read as a
    // flat yellow-white flood over the art).
    const float3 holo = min(accent * holoStrength, float3(bb_holo_cap));
    // saturate(): albedo must stay <= 1 or the lighting pass amplifies it.
    color = saturate(color + holo);

    // Grayscale LAST so unowned cards desaturate the full composite.
    color = mix(color, float3(bb_card_luminance(color)), grayscaleAmount);

    params.surface().set_base_color(half3(color));

    // A slice of the holo term glows so the foil reads even in dim lighting
    // (grayscaled the same way — luminance is linear, so this stays
    // equivalent to desaturating the final composite).
    float3 glow = holo * 0.30f;
    glow = mix(glow, float3(bb_card_luminance(glow)), grayscaleAmount);
    params.surface().set_emissive_color(half3(glow));

    params.surface().set_roughness(half(mix(0.42f, roughness, holoStrength)));
    params.surface().set_metallic(half(0.0f));
    params.surface().set_specular(half(specular));
    params.surface().set_ambient_occlusion(half(1.0f));
}
