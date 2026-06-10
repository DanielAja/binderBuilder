//
//  RoundedRectOutline.swift
//  binderBuilder
//
//  2D outline of a rounded rectangle centered on the origin, built from four
//  corner arcs. Pure math (nonisolated) so it is unit-testable without a
//  scene; CardMesh extrudes this outline into the card slab.
//

import simd

nonisolated enum RoundedRectOutline {
    struct OutlineVertex: Equatable {
        /// Point on the outline, in the rect's local XY plane.
        var position: SIMD2<Float>
        /// Outward unit normal at the point (radial from the corner center;
        /// arcs are tangent to the straight edges, so normals are continuous
        /// around the whole outline).
        var normal: SIMD2<Float>
    }

    /// Counter-clockwise outline (viewed from +z) of a `width` x `height`
    /// rounded rect. Each corner contributes `segmentsPerCorner + 1` points;
    /// consecutive arcs are joined implicitly by the straight edges, so the
    /// closed polygon has `4 * (segmentsPerCorner + 1)` vertices.
    /// Order: bottom-right, top-right, top-left, bottom-left.
    static func vertices(
        width: Float,
        height: Float,
        cornerRadius: Float,
        segmentsPerCorner: Int
    ) -> [OutlineVertex] {
        precondition(width > 0 && height > 0, "degenerate rect")
        precondition(cornerRadius >= 0 && cornerRadius <= min(width, height) / 2, "radius too large")
        precondition(segmentsPerCorner >= 1, "need at least one segment per corner")

        let hw = width / 2
        let hh = height / 2
        let r = cornerRadius
        // CCW corner order with each arc's start angle: bottom-right spans
        // -90..0 degrees, then +90 degrees per subsequent corner.
        let cornerCenters: [SIMD2<Float>] = [
            SIMD2(hw - r, -(hh - r)),
            SIMD2(hw - r, hh - r),
            SIMD2(-(hw - r), hh - r),
            SIMD2(-(hw - r), -(hh - r)),
        ]

        var outline: [OutlineVertex] = []
        outline.reserveCapacity(4 * (segmentsPerCorner + 1))
        for (corner, center) in cornerCenters.enumerated() {
            let startAngle = -Float.pi / 2 + Float(corner) * .pi / 2
            for step in 0...segmentsPerCorner {
                let angle = startAngle + (.pi / 2) * Float(step) / Float(segmentsPerCorner)
                let normal = SIMD2<Float>(cos(angle), sin(angle))
                outline.append(OutlineVertex(position: center + r * normal, normal: normal))
            }
        }
        return outline
    }

    /// Signed area via the shoelace formula — positive for CCW winding.
    static func signedArea(of outline: [OutlineVertex]) -> Float {
        guard outline.count >= 3 else { return 0 }
        var sum: Float = 0
        for i in 0..<outline.count {
            let a = outline[i].position
            let b = outline[(i + 1) % outline.count].position
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }
}
