//
//  PageCurl.metal
//  binderBuilder
//
//  CustomMaterial shaders for the deformable binder page.
//  - pageCurlGeometryModifier: cylinder-slide curl as a geometry modifier.
//    Uniforms in custom_parameter() = float4(d, r, psi, unused).
//  - pageCurlSurface: minimal lit surface — samples the base color texture
//    and applies the material tint. (CustomMaterial requires a surface
//    shader; this one is a deliberate passthrough.)
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
    const float4 u = params.uniforms().custom_parameter(); // (d, r, psi, unused)
    const float3 p = params.geometry().model_position();
    const float3 n = params.geometry().normal();

    float3 outP;
    float3 outN;
    bb_page_curl(p, n, u.x, u.y, u.z, outP, outN);

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
