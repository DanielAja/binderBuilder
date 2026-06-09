//
//  PageCurl.metal
//  binderBuilder
//
//  CustomMaterial shaders for the deformable binder page.
//  - pageCurlGeometryModifier: cylinder-slide curl as a geometry modifier.
//    Uniforms in custom_parameter() = float4(d, r, psi, packedSagSway).
//  - pageCurlSurface: minimal lit surface — samples the base color texture
//    and applies the material tint. (CustomMaterial requires a surface
//    shader; this one is a deliberate passthrough.)
//  - sleeveSurface: translucent vinyl pocket surface with a brighter, more
//    opaque weld seam near the pocket edges (driven by the per-pocket UVs).
//    Used with `.transparent` blending so set_opacity is honored.
//
//  CPU twin of the curl math: Scene3D/Geometry/CurlFunction.swift.
//

#include <metal_stdlib>
#include <RealityKit/RealityKit.h>
#include "ShaderCommon.h"

using namespace metal;

[[visible]]
void pageCurlGeometryModifier(realitykit::geometry_parameters params)
{
    const float4 u = params.uniforms().custom_parameter(); // (d, r, psi, packedSagSway)
    const float3 p = params.geometry().model_position();
    const float3 n = params.geometry().normal();

    const float sag = bb_unpack_sag(u.w);

    float3 outP;
    float3 outN;
    bb_page_curl(p, n, u.x, u.y, u.z, sag, outP, outN);

    params.geometry().set_model_position_offset(outP - p);
    params.geometry().set_normal(outN);
}

[[visible]]
void pageCurlSurface(realitykit::surface_parameters params)
{
    constexpr sampler bilinear(filter::linear, address::repeat);

    float2 uv = params.geometry().uv0();
    // RealityKit texture coordinates are flipped vertically relative to MeshDescriptor UVs.
    uv.y = 1.0 - uv.y;

    const half4 base = params.textures().base_color().sample(bilinear, uv);
    const half3 tint = (half3)params.material_constants().base_color_tint().rgb;

    params.surface().set_base_color(base.rgb * tint);
    params.surface().set_roughness(half(0.85));
    params.surface().set_metallic(half(0.0));
    params.surface().set_specular(half(0.3));
    params.surface().set_ambient_occlusion(half(1.0));
}

[[visible]]
void sleeveSurface(realitykit::surface_parameters params)
{
    float2 uv = params.geometry().uv0();
    // Same vertical flip convention as pageCurlSurface (border math is
    // symmetric, but keep the convention consistent for future texture use).
    uv.y = 1.0 - uv.y;

    // Distance to the nearest pocket edge in UV space; pockets get a
    // brighter, more opaque "weld seam" rim so the 3x3 grid reads clearly.
    const float edge = min(min(uv.x, 1.0f - uv.x), min(uv.y, 1.0f - uv.y));
    const float seam = 1.0f - smoothstep(0.0f, 0.05f, edge);

    const half3 vinyl = half3(0.78h, 0.83h, 0.88h);
    params.surface().set_base_color(vinyl + half3(0.12h, 0.12h, 0.10h) * half(seam));
    params.surface().set_roughness(half(0.22));
    params.surface().set_metallic(half(0.0));
    params.surface().set_specular(half(0.7));
    params.surface().set_clearcoat(half(0.9));
    params.surface().set_clearcoat_roughness(half(0.25));
    params.surface().set_opacity(half(0.22 + 0.42 * seam));
    params.surface().set_ambient_occlusion(half(1.0));
}
