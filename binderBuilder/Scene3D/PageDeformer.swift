//
//  PageDeformer.swift
//  binderBuilder
//
//  Two interchangeable strategies for deforming the binder page with the
//  cylinder-slide curl, selected via the `-deformer gpu|cpu` launch argument
//  (default gpu):
//
//  - GPUPageDeformer: CustomMaterial geometry modifier (Metal vertex function
//    pageCurlGeometryModifier in Shaders/PageCurl.metal). update() only writes
//    the float4 uniform — the mesh never changes on the CPU.
//  - CPUPageDeformer: LowLevelMesh; update() recomputes all 41x31x2 vertices
//    with CurlFunction (the CPU twin) straight into the vertex buffer.
//

import Metal
import RealityKit
import UIKit
import simd

@MainActor
protocol PageDeformer: AnyObject {
    /// "gpu" or "cpu" — for logging and verification.
    var debugLabel: String { get }
    /// Builds the deformable page entity this deformer drives.
    func makePageEntity() throws -> ModelEntity
    /// Applies curl parameters to a page previously built by `makePageEntity`.
    func update(curl: CurlParams, on page: Entity)
}

enum PageDeformerError: Error {
    case metalUnavailable
    case defaultLibraryMissing
}

// MARK: - GPU (CustomMaterial geometry modifier)

@MainActor
final class GPUPageDeformer: PageDeformer {
    let debugLabel = "gpu"
    private let templateMaterial: CustomMaterial

    init(baseColorTexture: TextureResource) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw PageDeformerError.metalUnavailable
        }
        guard let library = device.makeDefaultLibrary() else {
            throw PageDeformerError.defaultLibraryMissing
        }
        let geometryModifier = CustomMaterial.GeometryModifier(
            named: "pageCurlGeometryModifier",
            in: library
        )
        let surfaceShader = CustomMaterial.SurfaceShader(
            named: "pageCurlSurface",
            in: library
        )
        var material = try CustomMaterial(
            surfaceShader: surfaceShader,
            geometryModifier: geometryModifier,
            lightingModel: .lit
        )
        material.baseColor = .init(tint: .white, texture: .init(baseColorTexture))
        material.custom.value = CurlParams.progress(0).float4
        templateMaterial = material
    }

    func makePageEntity() throws -> ModelEntity {
        let mesh = try PageMesh.makeMeshResource()
        // Two submeshes (front/back) share the one curl material.
        let page = ModelEntity(mesh: mesh, materials: [templateMaterial, templateMaterial])
        page.name = "Page"
        return page
    }

    func update(curl: CurlParams, on page: Entity) {
        guard var model = page.components[ModelComponent.self] else { return }
        model.materials = model.materials.map { material in
            guard var custom = material as? CustomMaterial else { return material }
            custom.custom.value = curl.float4
            return custom
        }
        page.components.set(model)
    }
}

// MARK: - CPU (LowLevelMesh fallback)

@MainActor
final class CPUPageDeformer: PageDeformer {
    let debugLabel = "cpu"

    /// 32-byte interleaved vertex: position(12) normal(12) uv(8).
    private struct Vertex {
        var px: Float, py: Float, pz: Float
        var nx: Float, ny: Float, nz: Float
        var u: Float, v: Float
    }

    private let lowLevelMesh: LowLevelMesh
    private let baseColorTexture: TextureResource
    private let positions: [SIMD3<Float>]
    private let uvs: [SIMD2<Float>]

    init(baseColorTexture: TextureResource) throws {
        self.baseColorTexture = baseColorTexture
        positions = PageMesh.gridPositions()
        uvs = PageMesh.gridUVs()

        let vertexCount = PageMesh.vertexCountPerSide * 2
        let indexCount = PageMesh.indexCountPerSide * 2

        var descriptor = LowLevelMesh.Descriptor()
        descriptor.vertexCapacity = vertexCount
        descriptor.vertexAttributes = [
            .init(semantic: .position, format: .float3, offset: 0),
            .init(semantic: .normal, format: .float3, offset: 12),
            .init(semantic: .uv0, format: .float2, offset: 24),
        ]
        descriptor.vertexLayouts = [.init(bufferIndex: 0, bufferStride: MemoryLayout<Vertex>.stride)]
        descriptor.indexCapacity = indexCount
        descriptor.indexType = .uint32

        lowLevelMesh = try LowLevelMesh(descriptor: descriptor)

        // Indices never change: front sheet over vertices 0..<n, back sheet
        // (reversed winding) over duplicated vertices n..<2n.
        let front = PageMesh.frontIndices()
        let backOffset = UInt32(PageMesh.vertexCountPerSide)
        let back = PageMesh.backIndices().map { $0 + backOffset }
        lowLevelMesh.withUnsafeMutableIndices { buffer in
            let indices = buffer.bindMemory(to: UInt32.self)
            for (k, value) in (front + back).enumerated() {
                indices[k] = value
            }
        }

        // Generous bounds: page footprint plus full curl height (2 * r).
        let bounds = BoundingBox(
            min: SIMD3<Float>(-0.05, -0.05, -0.13),
            max: SIMD3<Float>(PageMesh.width + 0.05, PageMesh.height + 0.05, 0.13)
        )
        lowLevelMesh.parts.replaceAll([
            LowLevelMesh.Part(
                indexCount: indexCount,
                topology: .triangle,
                bounds: bounds
            )
        ])

        writeVertices(curl: CurlParams.progress(0))
    }

    func makePageEntity() throws -> ModelEntity {
        let mesh = try MeshResource(from: lowLevelMesh)
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .white, texture: .init(baseColorTexture))
        material.roughness = 0.85
        material.metallic = 0.0
        let page = ModelEntity(mesh: mesh, materials: [material])
        page.name = "Page"
        return page
    }

    func update(curl: CurlParams, on page: Entity) {
        writeVertices(curl: curl)
    }

    private func writeVertices(curl: CurlParams) {
        let perSide = PageMesh.vertexCountPerSide
        lowLevelMesh.withUnsafeMutableBytes(bufferIndex: 0) { rawBuffer in
            let vertices = rawBuffer.bindMemory(to: Vertex.self)
            for i in 0..<perSide {
                let uv = uvs[i]
                let frontDeformed = CurlFunction.deform(
                    position: positions[i],
                    normal: SIMD3<Float>(0, 0, 1),
                    params: curl
                )
                vertices[i] = Vertex(
                    px: frontDeformed.position.x, py: frontDeformed.position.y, pz: frontDeformed.position.z,
                    nx: frontDeformed.normal.x, ny: frontDeformed.normal.y, nz: frontDeformed.normal.z,
                    u: uv.x, v: uv.y
                )
                let backDeformed = CurlFunction.deform(
                    position: positions[i],
                    normal: SIMD3<Float>(0, 0, -1),
                    params: curl
                )
                vertices[perSide + i] = Vertex(
                    px: backDeformed.position.x, py: backDeformed.position.y, pz: backDeformed.position.z,
                    nx: backDeformed.normal.x, ny: backDeformed.normal.y, nz: backDeformed.normal.z,
                    u: uv.x, v: uv.y
                )
            }
        }
    }
}
