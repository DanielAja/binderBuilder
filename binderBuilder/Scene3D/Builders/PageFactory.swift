//
//  PageFactory.swift
//  binderBuilder
//
//  Builds the pooled deformable page entities. Each pooled page gets its OWN
//  deformer instance (the CPU deformer owns a LowLevelMesh per instance, so
//  four pages deform independently — the earlier single-shared-mesh
//  limitation is gone). GPU is the default; any failure to build the
//  CustomMaterial falls back to the CPU path per page.
//

import OSLog
import RealityKit
import simd

@MainActor
enum PageFactory {
    private static let log = Logger(subsystem: "com.aja.binderBuilder", category: "PageFactory")

    struct PooledPage {
        let entity: ModelEntity
        let deformer: any PageDeformer
    }

    /// Orientation that lays a page-local mesh (x toward the free edge,
    /// y up the page, z front normal) flat onto the binder: local +z -> world
    /// +y (up), local +y -> world -z (away from camera).
    static let flatOrientation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))

    /// Page-local origin in binder space: x at the spine gap, z at the near
    /// edge of the stacks (page height runs toward -z). Y is set per frame
    /// by PageTurnSystem from the stack heights.
    static let pageOriginX: Float = BinderBuilder3D.stackInnerX
    static let pageOriginZ: Float = BinderBuilder3D.pageStackDepth / 2

    /// Builds `count` pooled pages. Returns the pages plus the label of the
    /// deformer kind actually in use after any fallback ("gpu" or "cpu").
    static func makePages(
        count: Int = PagePool.capacity,
        requested: DebugLaunchState.Deformer,
        texture: TextureResource
    ) -> (pages: [PooledPage], activeLabel: String) {
        var pages: [PooledPage] = []
        var label = "none"
        for index in 0..<count {
            guard let (deformer, kindLabel) = makeDeformer(requested: requested, texture: texture) else {
                continue
            }
            label = kindLabel
            do {
                let entity = try deformer.makePageEntity()
                entity.name = "PooledPage\(index)"
                entity.orientation = flatOrientation
                entity.position = SIMD3<Float>(pageOriginX, BinderBuilder3D.coverThickness, pageOriginZ)
                entity.isEnabled = false
                pages.append(PooledPage(entity: entity, deformer: deformer))
            } catch {
                log.error("Failed to build pooled page \(index): \(String(describing: error), privacy: .public)")
            }
        }
        return (pages, label)
    }

    private static func makeDeformer(
        requested: DebugLaunchState.Deformer,
        texture: TextureResource
    ) -> (any PageDeformer, String)? {
        if requested == .gpu {
            do {
                return (try GPUPageDeformer(baseColorTexture: texture), "gpu")
            } catch {
                log.error("GPU deformer unavailable (\(String(describing: error), privacy: .public)); falling back to CPU")
            }
        }
        do {
            return (try CPUPageDeformer(baseColorTexture: texture), "cpu")
        } catch {
            log.fault("CPU deformer also failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
