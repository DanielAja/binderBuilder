//
//  CardSurface.metal
//  binderBuilder
//
//  CustomMaterial SURFACE shader for the card front (no geometry modifier).
//  Composites: base art -> fresnel-driven iridescent rainbow + hashed sparkle
//  glints (both gated by the holo mask in the custom texture slot, flat white
//  when no mask is bound) -> grayscale LAST for unowned cards.
//
//  Uniforms in custom_parameter(), packed by HoloUniformSystem:
//    float4(holoStrength, grayscaleAmount, lightPhaseX, lightPhaseY)
//

#include <metal_stdlib>
#include <RealityKit/RealityKit.h>

using namespace metal;

static inline float bb_card_hash(float2 p)
{
    p = fract(p * float2(123.34f, 456.21f));
    p += dot(p, p + 45.32f);
    return fract(p.x * p.y);
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

[[visible]]
void cardSurface(realitykit::surface_parameters params)
{
    constexpr sampler bilinear(filter::linear, mip_filter::linear, address::clamp_to_edge);

    float2 uv = params.geometry().uv0();
    // RealityKit texture coordinates are flipped vertically relative to
    // MeshDescriptor UVs — flip to match PhysicallyBasedMaterial's convention.
    uv.y = 1.0f - uv.y;

    const float4 u = params.uniforms().custom_parameter();
    const float holoStrength = u.x;
    const float grayscaleAmount = u.y;
    const float2 lightPhase = u.zw;

    const half3 tint = (half3)params.material_constants().base_color_tint().rgb;
    const half4 baseSample = params.textures().base_color().sample(bilinear, uv);
    float3 color = float3(baseSample.rgb * tint);

    // Fresnel rim response from world-space normal vs view direction.
    const float3 N = normalize(params.geometry().normal());
    const float3 V = normalize(params.geometry().view_direction());
    const float fresnel = powr(1.0f - saturate(dot(N, V)), 2.0f);

    // Holo mask from the custom texture slot (flat 1x1 white when absent).
    const float mask = float(params.textures().custom().sample(bilinear, uv).r);

    // Iridescent rainbow: hue sweeps with the view direction (against a
    // stable horizontal tangent), the motion-driven light phase, and a
    // diagonal stripe across the card; fresnel brightens grazing angles.
    float3 tangent = cross(float3(0.0f, 1.0f, 0.0f), N);
    tangent = (length_squared(tangent) < 1e-5f) ? float3(1.0f, 0.0f, 0.0f) : normalize(tangent);
    const float hue = fract(1.7f * dot(V, tangent)
                            + lightPhase.x
                            + 0.45f * lightPhase.y
                            + uv.x * 1.25f
                            + uv.y * 0.35f);
    const float3 rainbow = bb_card_hue_ramp(hue);
    const float iridescence = 0.22f + 0.78f * fresnel;

    // Sparkle: hashed glint cells, re-seeded as the light phase moves,
    // gated (boosted) by fresnel.
    const float2 cell = floor(uv * float2(190.0f, 265.0f));
    const float glint = bb_card_hash(cell + floor(lightPhase * 23.0f));
    const float sparkle = step(0.992f, glint) * (0.35f + fresnel) * 2.0f;

    const float3 holo = (rainbow * iridescence * 0.65f + float3(sparkle)) * (mask * holoStrength);
    color += holo;

    // Grayscale LAST so unowned cards desaturate the full composite.
    color = mix(color, float3(bb_card_luminance(color)), grayscaleAmount);

    params.surface().set_base_color(half3(color));

    // A slice of the holo term glows so the foil reads even in dim lighting
    // (grayscaled the same way — luminance is linear, so this stays
    // equivalent to desaturating the final composite).
    float3 glow = holo * 0.30f;
    glow = mix(glow, float3(bb_card_luminance(glow)), grayscaleAmount);
    params.surface().set_emissive_color(half3(glow));

    params.surface().set_roughness(half(0.42f));
    params.surface().set_metallic(half(0.0f));
    params.surface().set_specular(half(0.5f));
    params.surface().set_ambient_occlusion(half(1.0f));
}
