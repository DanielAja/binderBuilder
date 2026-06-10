//
//  CardFactory.swift
//  binderBuilder
//
//  Builds card entities for binder pockets: the shared rounded-rect extruded
//  CardMesh with three material slots — a CustomMaterial holo surface on the
//  front (CardSurface.metal: iridescence + sparkle + grayscale-for-unowned),
//  and shared PBR for the back and rim. The front material's custom.value
//  packs float4(holoStrength, grayscaleAmount, lightPhaseX, lightPhaseY); the
//  motion system (Phase H) drives the light phase, here it starts at rest.
//

import Metal
import OSLog
import RealityKit
import UIKit
import simd

@MainActor
enum CardFactory {
    private static let log = Logger(subsystem: "com.aja.binderBuilder", category: "CardFactory")

    /// Foil strength per variant (drives the holo term in CardSurface).
    static func holoStrength(for variant: CardVariant) -> Float {
        switch variant {
        case .normal: return 0.10
        case .reverse: return 0.65
        case .holo: return 1.0
        case .firstEdition: return 0.5
        }
    }

    private static var cachedBack: PhysicallyBasedMaterial?
    private static var cachedSurfaceShader: CustomMaterial.SurfaceShader?

    /// Shared matte PBR for the card back and rim (one instance, batched).
    private static func backMaterial() -> PhysicallyBasedMaterial {
        if let cachedBack { return cachedBack }
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: .init(red: 0.12, green: 0.16, blue: 0.34, alpha: 1))
        m.roughness = 0.55
        m.metallic = 0.0
        cachedBack = m
        return m
    }

    private static func surfaceShader() -> CustomMaterial.SurfaceShader? {
        if let cachedSurfaceShader { return cachedSurfaceShader }
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = device.makeDefaultLibrary() else {
            log.error("Metal default library unavailable; cards fall back to PBR")
            return nil
        }
        let shader = CustomMaterial.SurfaceShader(named: "cardSurface", in: library)
        cachedSurfaceShader = shader
        return shader
    }

    /// Front holo material bound to `texture`, configured for the variant and
    /// ownership. Falls back to a plain PBR (textured) material if the custom
    /// shader can't be built.
    static func frontMaterial(
        texture: TextureResource,
        variant: CardVariant,
        owned: Bool
    ) -> Material {
        let grayscale: Float = owned ? 0 : 1
        if let shader = surfaceShader() {
            do {
                var custom = try CustomMaterial(surfaceShader: shader, lightingModel: .lit)
                custom.baseColor = .init(tint: .white, texture: .init(texture))
                custom.custom.value = SIMD4<Float>(holoStrength(for: variant), grayscale, 0, 0)
                custom.faceCulling = .back
                return custom
            } catch {
                log.error("CustomMaterial(cardSurface) failed: \(String(describing: error), privacy: .public)")
            }
        }
        var pbr = PhysicallyBasedMaterial()
        pbr.baseColor = .init(tint: owned ? .white : .init(white: 0.6, alpha: 1), texture: .init(texture))
        pbr.roughness = 0.45
        pbr.metallic = 0.0
        return pbr
    }

    /// Builds a card entity (centered on origin, +z front) carrying a
    /// CardSlotComponent. Texture is typically the placeholder at first; the
    /// coordinator swaps in real art when it arrives.
    static func makeCard(
        ref: CardRef,
        slot: Int,
        side: PageSide,
        owned: Bool,
        texture: TextureResource
    ) -> ModelEntity? {
        guard let mesh = try? CardMesh.sharedMesh() else {
            log.error("CardMesh unavailable")
            return nil
        }
        let back = backMaterial()
        let materials: [Material] = [
            frontMaterial(texture: texture, variant: ref.variant, owned: owned),
            back, // cardBack submesh
            back  // cardRim submesh
        ]
        let entity = ModelEntity(mesh: mesh, materials: materials)
        entity.name = "Card-\(side == .front ? "f" : "b")\(slot)"
        entity.components.set(CardSlotComponent(
            ref: ref,
            slot: slot,
            side: side,
            flatCenter: CardSlotGeometry.center(slot: slot, side: side)
        ))
        return entity
    }

    /// Rebinds the front material's texture/uniforms in place (owned toggle,
    /// art arrival) without rebuilding the entity.
    static func updateFront(
        _ entity: ModelEntity,
        texture: TextureResource,
        variant: CardVariant,
        owned: Bool
    ) {
        guard var model = entity.components[ModelComponent.self], !model.materials.isEmpty else { return }
        model.materials[0] = frontMaterial(texture: texture, variant: variant, owned: owned)
        entity.components.set(model)
    }

    /// Sets only the grayscale/holo uniforms on an existing CustomMaterial
    /// front (used by the live owned-toggle). No-op for the PBR fallback.
    static func setOwnership(_ entity: ModelEntity, owned: Bool, variant: CardVariant) {
        guard var model = entity.components[ModelComponent.self],
              var custom = model.materials.first as? CustomMaterial else { return }
        var value = custom.custom.value
        value.x = holoStrength(for: variant)
        value.y = owned ? 0 : 1
        custom.custom.value = value
        model.materials[0] = custom
        entity.components.set(model)
    }
}
