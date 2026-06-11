//
//  CardMesh.swift
//  binderBuilder
//
//  Shared card mesh: a rounded-rect outline (63 x 88 mm, 3 mm corner radius,
//  8 segments per corner) extruded to 0.6 mm, centered on the origin with +z
//  as the card front normal. THREE submeshes -> three material slots:
//    [0] cardFront — fan-triangulated face at z = +t/2, UV 0..1 over the
//        card rect (v = 0 at the card top, matching the project texture
//        convention: PhysicallyBasedMaterial and the flipped CustomMaterial
//        surface shader both show the image upright).
//    [1] cardBack  — mirrored face at z = -t/2, own UV 0..1 (u flipped so
//        the back art is not mirrored when viewed from behind).
//    [2] cardRim   — quad strip around the outline, radial normals, simple
//        wrap UV (u around the perimeter, v across the thickness).
//
//  All card entities share one cached MeshResource (sharedMesh()).
//

import RealityKit
import simd

@MainActor
enum CardMesh {
    nonisolated static let width: Float = 0.063
    nonisolated static let height: Float = 0.088
    nonisolated static let thickness: Float = 0.0006
    nonisolated static let cornerRadius: Float = 0.003
    nonisolated static let segmentsPerCorner = 8

    nonisolated static var outlineVertexCount: Int { 4 * (segmentsPerCorner + 1) }

    private static var cachedMesh: MeshResource?

    /// The one card mesh every card entity shares.
    static func sharedMesh() throws -> MeshResource {
        if let cachedMesh { return cachedMesh }
        let mesh = try makeMeshResource()
        cachedMesh = mesh
        return mesh
    }

    /// Front-face UV for a point on the card: u 0..1 left -> right,
    /// v 0..1 top -> bottom (v = 0 at the card top).
    nonisolated static func frontUV(for point: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(point.x / width + 0.5, 0.5 - point.y / height)
    }

    static func makeMeshResource() throws -> MeshResource {
        let outline = RoundedRectOutline.vertices(
            width: width,
            height: height,
            cornerRadius: cornerRadius,
            segmentsPerCorner: segmentsPerCorner
        )
        let n = outline.count
        let halfT = thickness / 2

        // MARK: Front face (center fan; outline is convex so a fan is exact).
        var frontPositions: [SIMD3<Float>] = [SIMD3(0, 0, halfT)]
        var frontUVs: [SIMD2<Float>] = [SIMD2(0.5, 0.5)]
        for vertex in outline {
            frontPositions.append(SIMD3(vertex.position.x, vertex.position.y, halfT))
            // Flip V: CardSurface.metal also flips v, and the net of both made
            // the art render upside-down on every card. One flip here lands the
            // image upright (card top -> image top).
            let uv = frontUV(for: vertex.position)
            frontUVs.append(SIMD2(uv.x, 1 - uv.y))
        }
        var frontIndices: [UInt32] = []
        frontIndices.reserveCapacity(n * 3)
        for i in 0..<n {
            let next = UInt32((i + 1) % n)
            // Outline is CCW viewed from +z, so (center, i, i+1) faces +z.
            frontIndices.append(contentsOf: [0, UInt32(i) + 1, next + 1])
        }
        var front = MeshDescriptor(name: "cardFront")
        front.positions = MeshBuffer(frontPositions)
        front.normals = MeshBuffer([SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: frontPositions.count))
        front.textureCoordinates = MeshBuffer(frontUVs)
        front.primitives = .triangles(frontIndices)

        // MARK: Back face (same outline at -z, reversed winding, u mirrored).
        var backPositions: [SIMD3<Float>] = [SIMD3(0, 0, -halfT)]
        var backUVs: [SIMD2<Float>] = [SIMD2(0.5, 0.5)]
        for vertex in outline {
            backPositions.append(SIMD3(vertex.position.x, vertex.position.y, -halfT))
            let uv = frontUV(for: vertex.position)
            backUVs.append(SIMD2(1 - uv.x, uv.y))
        }
        var backIndices: [UInt32] = []
        backIndices.reserveCapacity(n * 3)
        for i in 0..<n {
            let next = UInt32((i + 1) % n)
            backIndices.append(contentsOf: [0, next + 1, UInt32(i) + 1])
        }
        var back = MeshDescriptor(name: "cardBack")
        back.positions = MeshBuffer(backPositions)
        back.normals = MeshBuffer([SIMD3<Float>](repeating: SIMD3(0, 0, -1), count: backPositions.count))
        back.textureCoordinates = MeshBuffer(backUVs)
        back.primitives = .triangles(backIndices)

        // MARK: Rim (two verts per outline point: front edge then back edge).
        var rimPositions: [SIMD3<Float>] = []
        var rimNormals: [SIMD3<Float>] = []
        var rimUVs: [SIMD2<Float>] = []
        rimPositions.reserveCapacity(n * 2)
        for (i, vertex) in outline.enumerated() {
            let normal = SIMD3(vertex.normal.x, vertex.normal.y, 0)
            let u = Float(i) / Float(n)
            rimPositions.append(SIMD3(vertex.position.x, vertex.position.y, halfT))
            rimNormals.append(normal)
            rimUVs.append(SIMD2(u, 0))
            rimPositions.append(SIMD3(vertex.position.x, vertex.position.y, -halfT))
            rimNormals.append(normal)
            rimUVs.append(SIMD2(u, 1))
        }
        var rimIndices: [UInt32] = []
        rimIndices.reserveCapacity(n * 6)
        for i in 0..<n {
            let j = (i + 1) % n
            let frontI = UInt32(2 * i)
            let backI = frontI + 1
            let frontJ = UInt32(2 * j)
            let backJ = frontJ + 1
            // Outward-facing for the CCW outline.
            rimIndices.append(contentsOf: [frontI, backI, backJ, frontI, backJ, frontJ])
        }
        var rim = MeshDescriptor(name: "cardRim")
        rim.positions = MeshBuffer(rimPositions)
        rim.normals = MeshBuffer(rimNormals)
        rim.textureCoordinates = MeshBuffer(rimUVs)
        rim.primitives = .triangles(rimIndices)

        return try MeshResource.generate(from: [front, back, rim])
    }
}
