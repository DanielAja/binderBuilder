//
//  PageDeformer.swift
//  binderBuilder
//
//  Two interchangeable strategies for deforming a binder page with the
//  cylinder-slide curl, selected via the `-deformer gpu|cpu` launch argument
//  (default gpu):
//
//  - GPUPageDeformer: CustomMaterial geometry modifier (Metal vertex function
//    pageCurlGeometryModifier in Shaders/PageCurl.metal). update() only writes
//    the float4 uniform — the mesh never changes on the CPU.
//  - CPUPageDeformer: LowLevelMesh; update() recomputes every vertex (page
//    front/back sheets + sleeve pockets) with CurlFunction (the CPU twin)
//    straight into the vertex buffer.
//
//  POOLING CONTRACT: one deformer instance drives exactly ONE page entity.
//  (This fixes the earlier CPU limitation where multiple pages would have
//  shared a single LowLevelMesh — each instance now owns its own mesh.)
//  PageFactory creates a fresh deformer per pooled page.
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
    /// Call exactly once per deformer instance (see pooling contract above).
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
    private let pageMaterial: CustomMaterial
    private let sleeveMaterial: CustomMaterial
    private var didMakeEntity = false

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

        var page = try CustomMaterial(
            surfaceShader: CustomMaterial.SurfaceShader(named: "pageCurlSurface", in: library),
            geometryModifier: geometryModifier,
            lightingModel: .lit
        )
        page.baseColor = .init(tint: .white, texture: .init(baseColorTexture))
        page.custom.value = CurlParams.progress(0).float4
        pageMaterial = page

        // Sleeves need the SAME geometry modifier (deformation is per-material
        // in RealityKit) but a translucent vinyl surface; opacity comes from
        // the sleeveSurface shader (weld seams are more opaque than the film).
        var sleeve = try CustomMaterial(
            surfaceShader: CustomMaterial.SurfaceShader(named: "sleeveSurface", in: library),
            geometryModifier: geometryModifier,
            lightingModel: .lit
        )
        sleeve.blending = .transparent(opacity: .init(floatLiteral: 1.0))
        sleeve.custom.value = CurlParams.progress(0).float4
        sleeveMaterial = sleeve
    }

    func makePageEntity() throws -> ModelEntity {
        assert(!didMakeEntity, "PageDeformer drives exactly one page entity")
        didMakeEntity = true
        let mesh = try PageMesh.makeCombinedMeshResource()
        // Submesh order: pageFront, pageBack, sleeveFront, sleeveBack.
        let page = ModelEntity(mesh: mesh, materials: [pageMaterial, pageMaterial, sleeveMaterial, sleeveMaterial])
        page.name = "Page"
        return page
    }

    func update(curl: CurlParams, on page: Entity) {
        guard var model = page.components[ModelComponent.self] else { return }
        let packed = curl.float4
        model.materials = model.materials.map { material in
            guard var custom = material as? CustomMaterial else { return material }
            custom.custom.value = packed
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
    private let pagePositions: [SIMD3<Float>]
    private let pageUVs: [SIMD2<Float>]
    private let sleeveFrontPositions: [SIMD3<Float>]
    private let sleeveBackPositions: [SIMD3<Float>]
    private let sleeveUVs: [SIMD2<Float>]
    private var didMakeEntity = false

    init(baseColorTexture: TextureResource) throws {
        self.baseColorTexture = baseColorTexture
        pagePositions = PageMesh.gridPositions()
        pageUVs = PageMesh.gridUVs()
        sleeveFrontPositions = SleeveGeometry.positions(zOffset: SleeveGeometry.surfaceOffset)
        sleeveBackPositions = SleeveGeometry.positions(zOffset: -SleeveGeometry.surfaceOffset)
        sleeveUVs = SleeveGeometry.uvs()

        let pageVertexCount = PageMesh.vertexCountPerSide * 2
        let sleeveVertexCount = SleeveGeometry.vertexCountPerSide * 2
        let pageIndexCount = PageMesh.indexCountPerSide * 2
        let sleeveIndexCount = SleeveGeometry.indexCountPerSide * 2

        var descriptor = LowLevelMesh.Descriptor()
        descriptor.vertexCapacity = pageVertexCount + sleeveVertexCount
        descriptor.vertexAttributes = [
            .init(semantic: .position, format: .float3, offset: 0),
            .init(semantic: .normal, format: .float3, offset: 12),
            .init(semantic: .uv0, format: .float2, offset: 24),
        ]
        descriptor.vertexLayouts = [.init(bufferIndex: 0, bufferStride: MemoryLayout<Vertex>.stride)]
        descriptor.indexCapacity = pageIndexCount + sleeveIndexCount
        descriptor.indexType = .uint32

        lowLevelMesh = try LowLevelMesh(descriptor: descriptor)

        // Vertex layout: page front [0, P), page back [P, 2P),
        // sleeve front [2P, 2P+S), sleeve back [2P+S, 2P+2S).
        // Indices never change.
        let perSide = UInt32(PageMesh.vertexCountPerSide)
        let sleeveBase = perSide * 2
        let front = PageMesh.frontIndices()
        let back = PageMesh.backIndices().map { $0 + perSide }
        let sleeveFront = SleeveGeometry.indices(front: true, baseVertex: sleeveBase)
        let sleeveBack = SleeveGeometry.indices(
            front: false,
            baseVertex: sleeveBase + UInt32(SleeveGeometry.vertexCountPerSide)
        )
        lowLevelMesh.withUnsafeMutableIndices { buffer in
            let indices = buffer.bindMemory(to: UInt32.self)
            for (k, value) in (front + back + sleeveFront + sleeveBack).enumerated() {
                indices[k] = value
            }
        }

        // Bounds cover the whole flip sweep (page mirrors to -x at t == 1).
        let bounds = BoundingBox(
            min: PageMesh.deformationBoundsMin,
            max: PageMesh.deformationBoundsMax
        )
        lowLevelMesh.parts.replaceAll([
            LowLevelMesh.Part(
                indexOffset: 0,
                indexCount: pageIndexCount,
                topology: .triangle,
                materialIndex: 0,
                bounds: bounds
            ),
            LowLevelMesh.Part(
                indexOffset: pageIndexCount * MemoryLayout<UInt32>.stride,
                indexCount: sleeveIndexCount,
                topology: .triangle,
                materialIndex: 1,
                bounds: bounds
            ),
        ])

        writeVertices(curl: CurlParams.progress(0))
    }

    func makePageEntity() throws -> ModelEntity {
        assert(!didMakeEntity, "PageDeformer drives exactly one page entity")
        didMakeEntity = true
        let mesh = try MeshResource(from: lowLevelMesh)
        var paper = PhysicallyBasedMaterial()
        paper.baseColor = .init(tint: .white, texture: .init(baseColorTexture))
        paper.roughness = 0.85
        paper.metallic = 0.0
        let page = ModelEntity(mesh: mesh, materials: [paper, SleeveFactory.makeVinylMaterial()])
        page.name = "Page"
        return page
    }

    func update(curl: CurlParams, on page: Entity) {
        // Canonicalize through the packed uniform so quantized sag matches
        // the GPU path bit-for-bit.
        writeVertices(curl: CurlParams(float4: curl.float4))
    }

    private func writeVertices(curl: CurlParams) {
        let perSide = PageMesh.vertexCountPerSide
        let sleevePerSide = SleeveGeometry.vertexCountPerSide
        lowLevelMesh.withUnsafeMutableBytes(bufferIndex: 0) { rawBuffer in
            let vertices = rawBuffer.bindMemory(to: Vertex.self)

            func write(_ index: Int, _ position: SIMD3<Float>, _ normal: SIMD3<Float>, _ uv: SIMD2<Float>) {
                let out = CurlFunction.deform(position: position, normal: normal, params: curl)
                vertices[index] = Vertex(
                    px: out.position.x, py: out.position.y, pz: out.position.z,
                    nx: out.normal.x, ny: out.normal.y, nz: out.normal.z,
                    u: uv.x, v: uv.y
                )
            }

            for i in 0..<perSide {
                write(i, pagePositions[i], SIMD3<Float>(0, 0, 1), pageUVs[i])
                write(perSide + i, pagePositions[i], SIMD3<Float>(0, 0, -1), pageUVs[i])
            }
            let sleeveBase = perSide * 2
            for i in 0..<sleevePerSide {
                write(sleeveBase + i, sleeveFrontPositions[i], SIMD3<Float>(0, 0, 1), sleeveUVs[i])
                write(sleeveBase + sleevePerSide + i, sleeveBackPositions[i], SIMD3<Float>(0, 0, -1), sleeveUVs[i])
            }
        }
    }
}
