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
//  Full flip parameterization (progress t in 0...1):
//    phase A (t in [0, 0.5]):   d slides from pageWidth to 0 at constant r —
//                               the page curls up and over the spine.
//    phase B (t in (0.5, 1]):   d == 0 and r shrinks toward `restRadius`, so
//                               the page settles flat (mirrored, x -> -x) on
//                               the LEFT stack. t == 0 is flat-on-right,
//                               t == 1 is flat-on-left.
//
//  Sag: heavy pages droop. A parabolic bell over the material x coordinate
//  (zero at the spine and at the free edge, max in the middle) pulls lifted
//  material down along local -z, gated by how far off the surface it is
//  (lift = clamp(surfaceZ / r, 0, 1)) so flat-on-stack material never sinks.
//  The sag amplitude is quantized to 10 bits and packed together with a
//  reserved "sway" value into the 4th float of the GPU uniform.
//

import simd

/// Uniforms for one page curl. Packed into CustomMaterial `custom.value` as
/// float4(d, r, psi, packedSagSway) for the GPU geometry modifier.
nonisolated struct CurlParams: Equatable, Sendable {
    /// Distance (m) from the spine at which the curl starts. d >= page width means flat.
    var d: Float
    /// Cylinder radius (m).
    var r: Float
    /// Tilt of the cylinder axis around the page normal, radians.
    var psi: Float
    /// Downward droop amplitude (m, 0...maxSag) of the parabolic sag bell.
    var sag: Float
    /// Reserved for the motion agent's tilt sway, -1...1. Packed alongside
    /// sag in the 4th uniform component; not yet applied by the shader.
    var sway: Float

    /// Maximum representable sag (m). Must match BB_MAX_SAG in ShaderCommon.h.
    static let maxSag: Float = 0.02
    /// Cylinder radius when a flipped page rests flat on the left stack.
    static let restRadius: Float = 0.0015

    init(d: Float, r: Float, psi: Float, sag: Float = 0, sway: Float = 0) {
        self.d = d
        self.r = r
        self.psi = psi
        self.sag = sag
        self.sway = sway
    }

    /// Maps a 0...1 flip progress (the `-curl` launch argument, drag t,
    /// spring t) to curl params. progress 0 is exactly flat on the right;
    /// progress 1 is flat (mirrored) on the left. psi follows a gentle
    /// sin(pi*t) arc so both endpoints are perfectly flat; gesture/drag psi
    /// is added on top by PageTurnSystem.
    static func progress(
        _ value: Float,
        pageWidth: Float = PageMesh.width,
        radius: Float = 0.05,
        restRadius: Float = CurlParams.restRadius,
        maxPsi: Float = 0.12
    ) -> CurlParams {
        let c = min(max(value, 0), 1)
        let psi = maxPsi * sin(.pi * c)
        if c <= 0.5 {
            return CurlParams(d: (1 - 2 * c) * pageWidth, r: radius, psi: psi)
        }
        let k = (c - 0.5) / 0.5
        return CurlParams(d: 0, r: radius + (restRadius - radius) * k, psi: psi)
    }

    // MARK: Sag/sway packing

    /// Packs sag (0...maxSag -> 10 bits) and sway (-1...1 -> 10 bits) into a
    /// single exactly-representable float (max value 2^20 - 1 < 2^24).
    /// Must mirror the unpacking in Shaders/PageCurl.metal.
    static func packSagSway(sag: Float, sway: Float) -> Float {
        let sagQ = Int((min(max(sag / maxSag, 0), 1) * 1023).rounded())
        let swayQ = Int(((min(max(sway, -1), 1) * 0.5 + 0.5) * 1023).rounded())
        return Float((sagQ << 10) | swayQ)
    }

    static func unpackSagSway(_ packed: Float) -> (sag: Float, sway: Float) {
        let bits = Int(packed.rounded())
        let sagQ = (bits >> 10) & 1023
        let swayQ = bits & 1023
        return (Float(sagQ) / 1023 * maxSag, Float(swayQ) / 1023 * 2 - 1)
    }

    var float4: SIMD4<Float> {
        SIMD4(d, r, psi, Self.packSagSway(sag: sag, sway: sway))
    }

    /// Reconstructs params from the packed GPU uniform. The CPU deformer
    /// canonicalizes through this so quantized sag matches the GPU exactly.
    init(float4 v: SIMD4<Float>) {
        let (sag, sway) = Self.unpackSagSway(v.w)
        self.init(d: v.x, r: v.y, psi: v.z, sag: sag, sway: sway)
    }
}

nonisolated enum CurlFunction {
    /// Deforms one vertex. Returns the new position and (unit) normal.
    /// NOTE: sag intentionally does not re-derive the normal (the droop is
    /// shallow); keep that simplification mirrored in the Metal twin.
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

        var surfaceZ: Float = 0
        let x1 = x - params.d
        if x1 > 0 {
            let phi = min(x1 / r, Float.pi)
            let cp = cos(phi)
            let sp = sin(phi)
            // Surface point on the curl (for material originally at z == 0).
            let surfaceX = params.d + sp * r + (x1 > Float.pi * r ? -(x1 - Float.pi * r) : 0)
            surfaceZ = (1 - cp) * r
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

        // Parabolic sag bell over the material x coordinate, gated by lift so
        // flat material (on either stack) is unaffected. z in the cylinder
        // frame equals z in page space (the psi rotation is about z).
        let u = min(max(p.x / PageMesh.width, 0), 1)
        let bell = 4 * u * (1 - u)
        let lift = min(max(surfaceZ / r, 0), 1)
        z -= params.sag * bell * lift

        // Rotate back by +psi around z.
        let outP = SIMD3<Float>(cs * x - sn * y, sn * x + cs * y, z)
        let outN = SIMD3<Float>(cs * nx - sn * ny, sn * nx + cs * ny, nz)
        return (outP, outN)
    }
}
