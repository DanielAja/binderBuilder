//
//  SleeveFactory.swift
//  binderBuilder
//
//  Vinyl pocket sleeves for a binder page: a 3x3 grid of pocket quads with
//  realistic margins on the 0.24 x 0.30 m page.
//
//  DESIGN DECISION (documented): sleeves are NOT separate entities. The
//  pocket grids are baked into the page mesh as extra submeshes (front
//  sleeves and back sleeves) sharing the page's vertex deformation:
//  - GPU path: the CustomMaterial geometry modifier runs per vertex on every
//    submesh, so the pockets bend with the page automatically and exactly.
//  - CPU path: CPUPageDeformer writes the sleeve vertices through the same
//    CurlFunction each frame.
//  This guarantees identical deformation on both deformer paths with zero
//  per-frame transform syncing (the alternative — child entities re-posed by
//  evaluating CurlFunction at pocket centers — approximates the bend with a
//  rigid transform per pocket and visibly cracks at high curvature).
//
//  Each pocket quad is subdivided (POCKET_COLS x POCKET_ROWS segments) so it
//  follows the curl's curvature; vertices float `surfaceOffset` above/below
//  the page plane, riding the deformed surface frame via the thickness-offset
//  term in the curl math. Per-pocket UVs run 0...1 so the sleeve surface
//  shader can draw weld-seam borders.
//

import RealityKit
import UIKit
import simd

/// Pure pocket-grid geometry. nonisolated so tests and the CPU deformer can
/// evaluate it off-main.
nonisolated enum SleeveGeometry {
    /// Pocket sized for a 63 x 88 mm card with a little slack.
    static let pocketWidth: Float = 0.066
    static let pocketHeight: Float = 0.091
    /// Gap between adjacent pockets (weld land between seams).
    static let gap: Float = 0.004
    /// How far the sleeve film floats off the page surface (m).
    static let surfaceOffset: Float = 0.0007

    /// Subdivision of each pocket so it follows the curl curvature.
    static let pocketColumns = 10
    static let pocketRows = 12

    static let pocketsPerSide = 9

    static var marginX: Float { (PageMesh.width - 3 * pocketWidth - 2 * gap) / 2 }
    static var marginY: Float { (PageMesh.height - 3 * pocketHeight - 2 * gap) / 2 }

    static var vertexCountPerPocket: Int { (pocketColumns + 1) * (pocketRows + 1) }
    static var indexCountPerPocket: Int { pocketColumns * pocketRows * 6 }
    static var vertexCountPerSide: Int { vertexCountPerPocket * pocketsPerSide }
    static var indexCountPerSide: Int { indexCountPerPocket * pocketsPerSide }

    /// Lower-left corner of a pocket in page-local space. Slots are row-major
    /// with slot 0 at the TOP-left as seen from the page front (+z).
    static func pocketOrigin(slot: Int) -> SIMD2<Float> {
        precondition((0..<pocketsPerSide).contains(slot))
        let row = slot / 3
        let col = slot % 3
        let x = marginX + Float(col) * (pocketWidth + gap)
        let y = PageMesh.height - marginY - pocketHeight - Float(row) * (pocketHeight + gap)
        return SIMD2<Float>(x, y)
    }

    /// Flat positions for all 9 pockets at the given z offset (+ for the
    /// front side, - for the back side). Page-local space, slot-major.
    static func positions(zOffset: Float) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(vertexCountPerSide)
        for slot in 0..<pocketsPerSide {
            let origin = pocketOrigin(slot: slot)
            for j in 0...pocketRows {
                let y = origin.y + pocketHeight * Float(j) / Float(pocketRows)
                for i in 0...pocketColumns {
                    let x = origin.x + pocketWidth * Float(i) / Float(pocketColumns)
                    out.append(SIMD3<Float>(x, y, zOffset))
                }
            }
        }
        return out
    }

    /// Per-pocket UVs (0...1 across each pocket; v = 0 at the pocket top,
    /// matching the page mesh convention).
    static func uvs() -> [SIMD2<Float>] {
        var out: [SIMD2<Float>] = []
        out.reserveCapacity(vertexCountPerSide)
        for _ in 0..<pocketsPerSide {
            for j in 0...pocketRows {
                let v = 1 - Float(j) / Float(pocketRows)
                for i in 0...pocketColumns {
                    out.append(SIMD2<Float>(Float(i) / Float(pocketColumns), v))
                }
            }
        }
        return out
    }

    /// Triangle indices for all 9 pockets. `front == true` winds CCW viewed
    /// from +z; `false` reverses the winding for the back side.
    static func indices(front: Bool, baseVertex: UInt32 = 0) -> [UInt32] {
        var out: [UInt32] = []
        out.reserveCapacity(indexCountPerSide)
        let stride = UInt32(pocketColumns + 1)
        for slot in 0..<pocketsPerSide {
            let slotBase = baseVertex + UInt32(slot * vertexCountPerPocket)
            for j in 0..<pocketRows {
                for i in 0..<pocketColumns {
                    let v0 = slotBase + UInt32(j) * stride + UInt32(i)
                    let v1 = v0 + 1
                    let v2 = v1 + stride
                    let v3 = v0 + stride
                    if front {
                        out.append(contentsOf: [v0, v1, v2, v0, v2, v3])
                    } else {
                        out.append(contentsOf: [v0, v2, v1, v0, v3, v2])
                    }
                }
            }
        }
        return out
    }
}

/// Material helpers for the sleeve film.
@MainActor
enum SleeveFactory {
    /// Translucent vinyl for the CPU (PhysicallyBasedMaterial) path. The GPU
    /// path builds an equivalent CustomMaterial (sleeveSurface shader) inside
    /// GPUPageDeformer because it needs the shared geometry modifier.
    static func makeVinylMaterial() -> PhysicallyBasedMaterial {
        var vinyl = PhysicallyBasedMaterial()
        vinyl.baseColor = .init(tint: .init(red: 0.78, green: 0.83, blue: 0.88, alpha: 1))
        vinyl.roughness = 0.22
        vinyl.metallic = 0.0
        vinyl.clearcoat = .init(floatLiteral: 0.9)
        vinyl.clearcoatRoughness = .init(floatLiteral: 0.25)
        vinyl.blending = .transparent(opacity: .init(floatLiteral: 0.3))
        return vinyl
    }
}
