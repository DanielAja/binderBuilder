//
//  CurlFunction.swift
//  binderBuilder
//
//  CPU twin of the cylinder-slide page curl implemented in Shaders/PageCurl.metal
//  (bb_page_curl in Shaders/ShaderCommon.h). The two MUST stay numerically
//  identical: the GPU path deforms the page mesh, while the CPU path is used by
//  the LowLevelMesh fallback deformer and (in later phases) to evaluate card
//  slot transforms riding the curl.
//
//  Page-local space: x = 0 at the spine edge, +x toward the free edge,
//  y along the page height, +z is the page front normal. The page is flat at
//  z == 0; input z (page thickness offsets) rides along the deformed normal.
//
//  Model: "cylinder slide". A virtual cylinder of radius r rests on the page
//  at distance d from the spine, with its axis tilted by psi around the page
//  normal. Material with rotated-frame x' > d wraps up and over the cylinder
//  (angle phi = min(x'/r, pi)); material past the top of the cylinder
//  (x' > pi*r) continues flat, upside down, heading back toward the spine.
//

import simd

/// Uniforms for one page curl. Packed into CustomMaterial `custom.value` as
/// float4(d, r, psi, 0) for the GPU geometry modifier.
nonisolated struct CurlParams: Equatable, Sendable {
    /// Distance (m) from the spine at which the curl starts. d >= page width means flat.
    var d: Float
    /// Cylinder radius (m).
    var r: Float
    /// Tilt of the cylinder axis around the page normal, radians.
    var psi: Float

    init(d: Float, r: Float, psi: Float) {
        self.d = d
        self.r = r
        self.psi = psi
    }

    /// Maps a 0...1 curl progress (the `-curl` launch argument) to params.
    /// psi grows with progress so progress 0 is exactly flat for every vertex.
    static func progress(
        _ value: Float,
        pageWidth: Float = PageMesh.width,
        radius: Float = 0.05,
        maxPsi: Float = 0.12
    ) -> CurlParams {
        let c = min(max(value, 0), 1)
        return CurlParams(d: (1 - c) * pageWidth, r: radius, psi: maxPsi * c)
    }

    var float4: SIMD4<Float> { SIMD4(d, r, psi, 0) }
}

nonisolated enum CurlFunction {
    /// Deforms one vertex. Returns the new position and (unit) normal.
    static func deform(
        position p: SIMD3<Float>,
        normal n: SIMD3<Float>,
        params: CurlParams
    ) -> (position: SIMD3<Float>, normal: SIMD3<Float>) {
        let r = max(params.r, 1e-5)
        let cs = cos(params.psi)
        let sn = sin(params.psi)

        // Rotate by -psi around the page normal (z) at the spine origin -> cylinder frame.
        var x = cs * p.x + sn * p.y
        let y = -sn * p.x + cs * p.y
        var z = p.z
        var nx = cs * n.x + sn * n.y
        let ny = -sn * n.x + cs * n.y
        var nz = n.z

        let x1 = x - params.d
        if x1 > 0 {
            let phi = min(x1 / r, Float.pi)
            let cp = cos(phi)
            let sp = sin(phi)
            // Surface point on the curl (for material originally at z == 0).
            let surfaceX = params.d + sp * r + (x1 > Float.pi * r ? -(x1 - Float.pi * r) : 0)
            let surfaceZ = (1 - cp) * r
            // Local surface frame normal: (0,0,1) rotated by -phi about the cylinder axis (y').
            let frameNX = -sp
            let frameNZ = cp
            // Thickness offset rides the rotated frame.
            x = surfaceX + p.z * frameNX
            z = surfaceZ + p.z * frameNZ
            // Rotate the vertex normal by -phi about the cylinder axis.
            let rnx = nx * cp - nz * sp
            let rnz = nx * sp + nz * cp
            nx = rnx
            nz = rnz
        }

        // Rotate back by +psi around z.
        let outP = SIMD3<Float>(cs * x - sn * y, sn * x + cs * y, z)
        let outN = SIMD3<Float>(cs * nx - sn * ny, sn * nx + cs * ny, nz)
        return (outP, outN)
    }
}
