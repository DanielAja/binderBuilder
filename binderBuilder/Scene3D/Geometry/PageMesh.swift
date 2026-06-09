//
//  PageMesh.swift
//  binderBuilder
//
//  Procedural binder-page mesh: a 40x30-segment plane, 0.24 m wide (x) by
//  0.30 m tall (y), positions in page-local space with x = 0 at the spine edge
//  and +x toward the free edge. UVs run 0...1 across the page.
//
//  Two-sided strategy (documented decision): the page is built as TWO
//  submeshes over duplicated vertices — a front sheet (normals +z, CCW
//  winding seen from +z) and a back sheet (normals -z, reversed winding).
//  Duplicating vertices (rather than disabling face culling on one sheet)
//  gives each side correct normals so the curl shading reads properly on
//  both faces, for GPU (geometry modifier runs per duplicated vertex) and
//  CPU (LowLevelMesh recomputes both sheets) deformers alike.
//

import RealityKit
import simd

nonisolated enum PageMesh {
    static let width: Float = 0.24
    static let height: Float = 0.30
    static let columns = 40 // segments along x
    static let rows = 30 // segments along y

    static var vertexCountPerSide: Int { (columns + 1) * (rows + 1) }
    static var indexCountPerSide: Int { columns * rows * 6 }

    /// Flat grid positions in page-local space (z == 0).
    static func gridPositions() -> [SIMD3<Float>] {
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(vertexCountPerSide)
        for j in 0...rows {
            let y = height * Float(j) / Float(rows)
            for i in 0...columns {
                let x = width * Float(i) / Float(columns)
                positions.append(SIMD3<Float>(x, y, 0))
            }
        }
        return positions
    }

    /// UVs: u = 0 at the spine, 1 at the free edge; v = 0 at the page top.
    static func gridUVs() -> [SIMD2<Float>] {
        var uvs: [SIMD2<Float>] = []
        uvs.reserveCapacity(vertexCountPerSide)
        for j in 0...rows {
            let v = 1 - Float(j) / Float(rows)
            for i in 0...columns {
                uvs.append(SIMD2<Float>(Float(i) / Float(columns), v))
            }
        }
        return uvs
    }

    /// Front-face indices: counter-clockwise viewed from +z.
    static func frontIndices() -> [UInt32] {
        var indices: [UInt32] = []
        indices.reserveCapacity(indexCountPerSide)
        let stride = UInt32(columns + 1)
        for j in 0..<rows {
            for i in 0..<columns {
                let v0 = UInt32(j) * stride + UInt32(i)
                let v1 = v0 + 1
                let v2 = v1 + stride
                let v3 = v0 + stride
                indices.append(contentsOf: [v0, v1, v2, v0, v2, v3])
            }
        }
        return indices
    }

    /// Back-face indices over the same grid ordering, winding reversed.
    static func backIndices() -> [UInt32] {
        var indices = frontIndices()
        for k in Swift.stride(from: 0, to: indices.count, by: 3) {
            indices.swapAt(k + 1, k + 2)
        }
        return indices
    }

    /// Conservative page-local bounds covering the whole flip sweep: the page
    /// mirrors to x in [-width, 0] when flipped left and lifts to z ~ 2r.
    /// Used for bounds padding (GPU) and LowLevelMesh part bounds (CPU) so
    /// RealityKit never frustum-culls a mid-flip page.
    static var deformationBoundsMin: SIMD3<Float> { SIMD3<Float>(-width - 0.02, -0.01, -0.02) }
    static var deformationBoundsMax: SIMD3<Float> { SIMD3<Float>(width + 0.02, height + 0.01, 0.13) }

    /// Standard MeshResource (two submeshes -> expects two materials).
    /// Used by the GPU deformer; the CPU deformer builds a LowLevelMesh instead.
    static func makeMeshResource() throws -> MeshResource {
        let positions = gridPositions()
        let uvs = gridUVs()

        var front = MeshDescriptor(name: "pageFront")
        front.positions = MeshBuffer(positions)
        front.normals = MeshBuffer([SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 1), count: positions.count))
        front.textureCoordinates = MeshBuffer(uvs)
        front.primitives = .triangles(frontIndices())

        var back = MeshDescriptor(name: "pageBack")
        back.positions = MeshBuffer(positions)
        back.normals = MeshBuffer([SIMD3<Float>](repeating: SIMD3<Float>(0, 0, -1), count: positions.count))
        back.textureCoordinates = MeshBuffer(uvs)
        back.primitives = .triangles(backIndices())

        return try MeshResource.generate(from: [front, back])
    }

    /// Full page mesh for the GPU deformer: four submeshes in material order
    /// [pageFront, pageBack, sleeveFront, sleeveBack]. The sleeve pockets
    /// share the page's deformation because the geometry modifier runs per
    /// vertex on every submesh (see SleeveFactory.swift for the rationale).
    ///
    /// The front submesh additionally carries two degenerate "bounds anchor"
    /// triangles at the extremes of the flip sweep so the static MeshResource
    /// bounds cover every deformed pose (the geometry modifier displaces
    /// vertices but cannot grow culling bounds).
    static func makeCombinedMeshResource() throws -> MeshResource {
        var positions = gridPositions()
        var uvs = gridUVs()
        var normals = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 1), count: positions.count)

        // Bounds anchors: x outside [0, width] never deforms (x' < d is
        // impossible only for x > d; padding at -x never curls, and padding
        // at +x deforms but its undeformed position is what bounds use).
        let anchorBase = UInt32(positions.count)
        positions.append(deformationBoundsMin)
        positions.append(deformationBoundsMax)
        uvs.append(SIMD2<Float>(0, 0))
        uvs.append(SIMD2<Float>(0, 0))
        normals.append(SIMD3<Float>(0, 0, 1))
        normals.append(SIMD3<Float>(0, 0, 1))
        var frontIdx = frontIndices()
        frontIdx.append(contentsOf: [anchorBase, anchorBase, anchorBase])
        frontIdx.append(contentsOf: [anchorBase + 1, anchorBase + 1, anchorBase + 1])

        var front = MeshDescriptor(name: "pageFront")
        front.positions = MeshBuffer(positions)
        front.normals = MeshBuffer(normals)
        front.textureCoordinates = MeshBuffer(uvs)
        front.primitives = .triangles(frontIdx)

        let backPositions = gridPositions()
        var back = MeshDescriptor(name: "pageBack")
        back.positions = MeshBuffer(backPositions)
        back.normals = MeshBuffer([SIMD3<Float>](repeating: SIMD3<Float>(0, 0, -1), count: backPositions.count))
        back.textureCoordinates = MeshBuffer(gridUVs())
        back.primitives = .triangles(backIndices())

        let sleeveUVs = SleeveGeometry.uvs()

        var sleeveFront = MeshDescriptor(name: "sleeveFront")
        let sleeveFrontPositions = SleeveGeometry.positions(zOffset: SleeveGeometry.surfaceOffset)
        sleeveFront.positions = MeshBuffer(sleeveFrontPositions)
        sleeveFront.normals = MeshBuffer(
            [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 1), count: sleeveFrontPositions.count))
        sleeveFront.textureCoordinates = MeshBuffer(sleeveUVs)
        sleeveFront.primitives = .triangles(SleeveGeometry.indices(front: true))

        var sleeveBack = MeshDescriptor(name: "sleeveBack")
        let sleeveBackPositions = SleeveGeometry.positions(zOffset: -SleeveGeometry.surfaceOffset)
        sleeveBack.positions = MeshBuffer(sleeveBackPositions)
        sleeveBack.normals = MeshBuffer(
            [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, -1), count: sleeveBackPositions.count))
        sleeveBack.textureCoordinates = MeshBuffer(sleeveUVs)
        sleeveBack.primitives = .triangles(SleeveGeometry.indices(front: false))

        return try MeshResource.generate(from: [front, back, sleeveFront, sleeveBack])
    }
}
