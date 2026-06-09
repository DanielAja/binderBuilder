//
//  SceneBootstrap.swift
//  binderBuilder
//
//  Assembles the 3D scene root for BinderSceneView: CameraRig + lights +
//  ground + procedural open binder + the single deformable test page.
//  Honors DebugLaunchState: -curl <0..1> freezes the page curl, and
//  -deformer gpu|cpu selects the PageDeformer implementation (default gpu,
//  with automatic CPU fallback if the GPU material fails to build).
//

import CoreGraphics
import OSLog
import RealityKit
import UIKit
import simd

@MainActor
struct SceneBootstrapResult {
    let root: Entity
    let cameraRig: CameraRig
    let deformer: any PageDeformer
    let page: ModelEntity?
    /// "gpu" or "cpu" — what actually got used after any fallback.
    let activeDeformerLabel: String
}

@MainActor
enum SceneBootstrap {
    private static let log = Logger(subsystem: "com.aja.binderBuilder", category: "SceneBootstrap")

    static func assemble(launchState: DebugLaunchState = .current) -> SceneBootstrapResult {
        let root = Entity()
        root.name = "SceneRoot"

        // Camera.
        let cameraRig = CameraRig()
        root.addChild(cameraRig.root)

        // Lights: directional key + dim point fill (IBL deferred to a later phase).
        let key = DirectionalLight()
        key.name = "KeyLight"
        key.light.intensity = 4200
        key.light.color = .init(red: 1.0, green: 0.97, blue: 0.92, alpha: 1)
        key.look(at: .zero, from: SIMD3<Float>(0.55, 1.4, 0.75), relativeTo: nil)
        root.addChild(key)

        let fill = PointLight()
        fill.name = "FillLight"
        fill.light.intensity = 8000
        fill.light.attenuationRadius = 4
        fill.light.color = .init(red: 0.85, green: 0.9, blue: 1.0, alpha: 1)
        fill.position = SIMD3<Float>(-0.5, 0.55, 0.45)
        root.addChild(fill)

        // Neutral dark ground plane (thin box).
        var groundMaterial = PhysicallyBasedMaterial()
        groundMaterial.baseColor = .init(tint: .init(white: 0.16, alpha: 1))
        groundMaterial.roughness = 0.95
        groundMaterial.metallic = 0.0
        let ground = ModelEntity(
            mesh: .generateBox(width: 1.6, height: 0.01, depth: 1.6, cornerRadius: 0.005),
            materials: [groundMaterial]
        )
        ground.name = "Ground"
        ground.position = SIMD3<Float>(0, -0.005, 0)
        root.addChild(ground)

        // Open binder.
        let binder = BinderBuilder3D.makeOpenBinder()
        root.addChild(binder)

        // Deformable test page on the right side of the spread.
        let texture = try? Self.makeCheckerTexture()
        let (deformer, activeLabel) = Self.makeDeformer(
            requested: launchState.deformer ?? .gpu,
            texture: texture
        )

        var page: ModelEntity?
        do {
            let entity = try deformer.makePageEntity()
            // Page-local: x=0 spine edge, +x free edge, +z front normal.
            // World: lie flat on the right page stack (local +z -> world +y,
            // local +y -> world -z, i.e. page height runs away from camera).
            entity.orientation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
            entity.position = SIMD3<Float>(
                0.01,
                BinderBuilder3D.pageRestHeight + 0.0008,
                BinderBuilder3D.pageStackDepth / 2
            )
            binder.addChild(entity)
            page = entity

            let progress = launchState.curl ?? 0
            deformer.update(curl: .progress(progress), on: entity)
            log.info("Page deformer active: \(activeLabel, privacy: .public), curl progress \(progress, privacy: .public)")
        } catch {
            log.error("Failed to build page entity: \(String(describing: error), privacy: .public)")
        }

        return SceneBootstrapResult(
            root: root,
            cameraRig: cameraRig,
            deformer: deformer,
            page: page,
            activeDeformerLabel: activeLabel
        )
    }

    /// Builds the requested deformer; if the GPU CustomMaterial cannot be
    /// created (no Metal device / missing shader function), falls back to CPU.
    private static func makeDeformer(
        requested: DebugLaunchState.Deformer,
        texture: TextureResource?
    ) -> (any PageDeformer, String) {
        let texture = texture ?? Self.fallbackTexture()
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
            // Last resort: a GPU deformer attempt so we return *something*;
            // callers treat a missing page gracefully.
            log.fault("CPU deformer also failed: \(String(describing: error), privacy: .public)")
            return ((try? GPUPageDeformer(baseColorTexture: texture)) ?? DummyDeformerHolder.shared, "none")
        }
    }

    // MARK: Test texture

    /// Procedural checker + gradient so any deformation is visually obvious:
    /// 8x10 checker in light gray/white, red tide toward the free edge (u=1)
    /// and a blue band along the top, over the full 0..1 UV range.
    static func makeCheckerTexture() throws -> TextureResource {
        let width = 512
        let height = 640
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PageDeformerError.metalUnavailable
        }

        let cols = 8
        let rows = 10
        let cellW = CGFloat(width) / CGFloat(cols)
        let cellH = CGFloat(height) / CGFloat(rows)
        for row in 0..<rows {
            for col in 0..<cols {
                let even = (row + col) % 2 == 0
                let redTide = 0.15 + 0.75 * CGFloat(col) / CGFloat(cols - 1)
                let base: CGFloat = even ? 0.92 : 0.62
                context.setFillColor(CGColor(
                    red: min(1, base * 0.6 + redTide * 0.4),
                    green: base * (even ? 0.95 : 0.75),
                    blue: base * (even ? 0.9 : 0.7),
                    alpha: 1
                ))
                context.fill(CGRect(
                    x: CGFloat(col) * cellW,
                    y: CGFloat(row) * cellH,
                    width: cellW.rounded(.up),
                    height: cellH.rounded(.up)
                ))
            }
        }
        // Blue band along the image top (v near 0 in mesh UVs after flip —
        // the far/top edge of the page).
        context.setFillColor(CGColor(red: 0.2, green: 0.35, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: CGFloat(height) - cellH / 2, width: CGFloat(width), height: cellH / 2))
        // Dark stripe at the free edge (u = 1).
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1))
        context.fill(CGRect(x: CGFloat(width) - cellW / 4, y: 0, width: cellW / 4, height: CGFloat(height)))

        guard let image = context.makeImage() else {
            throw PageDeformerError.metalUnavailable
        }
        return try TextureResource(
            image: image,
            options: .init(semantic: .color)
        )
    }

    private static func fallbackTexture() -> TextureResource {
        // 1x1 white pixel; only hit if CoreGraphics fails, which it does not.
        try! TextureResource(
            image: {
                let ctx = CGContext(
                    data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )!
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
                return ctx.makeImage()!
            }(),
            options: .init(semantic: .color)
        )
    }
}

/// Inert deformer used only if both real implementations fail to initialize.
@MainActor
private final class DummyDeformerHolder: PageDeformer {
    static let shared = DummyDeformerHolder()
    let debugLabel = "none"
    func makePageEntity() throws -> ModelEntity { throw PageDeformerError.metalUnavailable }
    func update(curl: CurlParams, on page: Entity) {}
}
