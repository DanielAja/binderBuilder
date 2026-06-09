//
//  ShaderCommon.h
//  binderBuilder
//
//  Shared Metal-side math for the page curl. The CPU twin lives in
//  Scene3D/Geometry/CurlFunction.swift — keep both numerically identical.
//
//  Page-local space: x = 0 at the spine edge, +x toward the free edge,
//  y along page height, +z page front normal. Uniforms arrive in the
//  CustomMaterial custom parameter as float4(d, r, psi, unused).
//

#ifndef ShaderCommon_h
#define ShaderCommon_h

#ifdef __METAL_VERSION__

#include <metal_stdlib>

/// Cylinder-slide curl. Deforms position `p` with normal `n` using curl
/// distance `d`, cylinder radius `r`, and axis tilt `psi` (radians, around
/// the page normal at the spine origin). Writes deformed position/normal.
inline void bb_page_curl(float3 p, float3 n,
                         float d, float r, float psi,
                         thread float3 &outP, thread float3 &outN)
{
    r = metal::max(r, 1e-5f);
    const float cs = metal::cos(psi);
    const float sn = metal::sin(psi);

    // Rotate by -psi around the page normal (z) -> cylinder frame.
    float x = cs * p.x + sn * p.y;
    float y = -sn * p.x + cs * p.y;
    float z = p.z;
    float nx = cs * n.x + sn * n.y;
    float ny = -sn * n.x + cs * n.y;
    float nz = n.z;

    const float x1 = x - d;
    if (x1 > 0.0f) {
        const float phi = metal::min(x1 / r, float(M_PI_F));
        const float cp = metal::cos(phi);
        const float sp = metal::sin(phi);
        const float surfaceX = d + sp * r + ((x1 > M_PI_F * r) ? -(x1 - M_PI_F * r) : 0.0f);
        const float surfaceZ = (1.0f - cp) * r;
        // Local surface frame normal: (0,0,1) rotated by -phi about the cylinder axis (y').
        const float frameNX = -sp;
        const float frameNZ = cp;
        x = surfaceX + p.z * frameNX;
        z = surfaceZ + p.z * frameNZ;
        // Rotate the vertex normal by -phi about the cylinder axis.
        const float rnx = nx * cp - nz * sp;
        const float rnz = nx * sp + nz * cp;
        nx = rnx;
        nz = rnz;
    }

    // Rotate back by +psi around z.
    outP = float3(cs * x - sn * y, sn * x + cs * y, z);
    outN = float3(cs * nx - sn * ny, sn * nx + cs * ny, nz);
}

#endif /* __METAL_VERSION__ */

#endif /* ShaderCommon_h */
