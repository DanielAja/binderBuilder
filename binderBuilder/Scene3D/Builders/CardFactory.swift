//
//  CardFactory.swift
//  binderBuilder
//
//  Builds card entities for binder pockets: the shared rounded-rect extruded
//  CardMesh with three material slots — a CustomMaterial holo surface on the
//  front (CardSurface.metal: a per-rarity foil accent + grayscale-for-unowned),
//  and shared PBR for the back and rim.
//
//  The front material's custom.value is the single float4 RealityKit gives a
//  CustomMaterial, packed by FoilUniforms:
//
//      .x = FoilTier code + holoStrength
//      .y = art-box era + grayscaleAmount
//      .zw = light phase — written every frame by MotionUpdateSystem, so
//            nothing here may clobber it after the material is bound.
//
//  The foil tier comes from the card's rarity string + physical variant
//  (FoilTier.resolve); the motion system drives the light phase, here it
//  starts at rest.
//

import Metal
import OSLog
import RealityKit
import UIKit
import simd

@MainActor
enum CardFactory {
    private static let log = Logger(subsystem: "com.aja.binderBuilder", category: "CardFactory")

    /// Foil amplitude for a printing. The TIER owns the loudness (a hyper rare
    /// is a hyper rare whether or not the catalog flags a holo printing); the
    /// physical variant only nudges it, and only for the flat tier where a
    /// first-edition/normal stamp is all we know.
    static func holoStrength(for variant: CardVariant, tier: FoilTier) -> Float {
        switch tier {
        case .none:
            return variant == .firstEdition ? 0.30 : 0.10
        default:
            return tier.intensity
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
        owned: Bool,
        foil: FoilTier = .none,
        artBoxEra: Int = 0
    ) -> Material {
        let grayscale: Float = owned ? 0 : 1
        if let shader = surfaceShader() {
            do {
                var custom = try CustomMaterial(surfaceShader: shader, lightingModel: .lit)
                custom.baseColor = .init(tint: .white, texture: .init(texture))
                custom.custom.value = SIMD4<Float>(
                    FoilUniforms.packTier(foil, strength: holoStrength(for: variant, tier: foil)),
                    FoilUniforms.packEra(artBoxEra, grayscale: grayscale),
                    0.5,
                    0
                )
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
        texture: TextureResource,
        foil: FoilTier = .none
    ) -> ModelEntity? {
        guard let mesh = try? CardMesh.sharedMesh() else {
            log.error("CardMesh unavailable")
            return nil
        }
        let back = backMaterial()
        let materials: [Material] = [
            frontMaterial(
                texture: texture,
                variant: ref.variant,
                owned: owned,
                foil: foil,
                artBoxEra: FoilTier.artBoxEra(cardID: ref.cardID)
            ),
            back, // cardBack submesh
            back  // cardRim submesh
        ]
        let entity = ModelEntity(mesh: mesh, materials: materials)
        entity.name = "Card-\(side == .front ? "f" : "b")\(slot)"
        entity.components.set(CardSlotComponent(
            ref: ref,
            slot: slot,
            side: side,
            flatCenter: CardSlotGeometry.center(slot: slot, side: side),
            foil: foil
        ))
        return entity
    }

    /// Rebinds the front material's texture/uniforms in place (owned toggle,
    /// art arrival) without rebuilding the entity.
    static func updateFront(
        _ entity: ModelEntity,
        texture: TextureResource,
        variant: CardVariant,
        owned: Bool,
        foil: FoilTier = .none,
        artBoxEra: Int = 0
    ) {
        guard var model = entity.components[ModelComponent.self], !model.materials.isEmpty else { return }
        model.materials[0] = frontMaterial(
            texture: texture, variant: variant, owned: owned, foil: foil, artBoxEra: artBoxEra
        )
        entity.components.set(model)
    }

    /// Flips only the grayscale bit on an existing CustomMaterial front (used
    /// by the live owned-toggle). The packed tier/strength in `.x`, the era in
    /// `.y`, and the motion system's light phase in `.zw` are all preserved —
    /// ownership says nothing about which foil a printing has. No-op for the
    /// PBR fallback.
    static func setOwnership(_ entity: ModelEntity, owned: Bool, variant: CardVariant) {
        guard var model = entity.components[ModelComponent.self],
              var custom = model.materials.first as? CustomMaterial else { return }
        var value = custom.custom.value
        value.y = FoilUniforms.withGrayscale(value.y, owned ? 0 : 1)
        guard value != custom.custom.value else { return }
        custom.custom.value = value
        model.materials[0] = custom
        entity.components.set(model)
    }
}
