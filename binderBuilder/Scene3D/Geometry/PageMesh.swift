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
}
