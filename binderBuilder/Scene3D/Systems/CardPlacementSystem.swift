//
//  CardPlacementSystem.swift
//  binderBuilder
//
//  Two halves of putting cards on pages:
//
//  - CardPlacement (coordinator): on every pool rebind, diffs each bound
//    page's card children against the content provider's snapshot — creating,
//    re-texturing, or removing card entities — and kicks async art loads
//    through CardTextureCache. Disabled pool pages have their cards cleared.
//
//  - CardPlacementSystem (per-frame): poses each card rigidly at its pocket's
//    curl frame by evaluating CurlFunction at the pocket center (a real card
//    doesn't bend). Runs AFTER PageTurnSystem so it reads the page's freshly
//    applied CurlParams; skips cards whose params are unchanged (rest pages
//    cost nothing).
//

import OSLog
import RealityKit
import simd

// MARK: - Per-frame posing

@MainActor
final class CardPlacementSystem: System {
    private static let query = EntityQuery(where: .has(PageComponent.self))
    private static var didRegister = false

    static func ensureRegistered() {
        guard !didRegister else { return }
        didRegister = true
        CardSlotComponent.registerComponent()
        registerSystem()
    }

    init(scene: Scene) {}

    func update(context: SceneUpdateContext) {
        for page in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard let pc = page.components[PageComponent.self], let params = pc.appliedParams else { continue }
            for child in page.children {
                guard var slot = child.components[CardSlotComponent.self],
                      let card = child as? ModelEntity else { continue }
                if slot.lastParams == params { continue }
                Self.pose(card, slot: slot, params: params)
                slot.lastParams = params
                card.components.set(slot)
            }
        }
    }

    /// Rigidly seats a card at its pocket's deformed curl frame (page-local).
    static func pose(_ card: ModelEntity, slot: CardSlotComponent, params: CurlParams) {
        let eps: Float = 0.001
        let up = SIMD3<Float>(0, 0, 1)
        let c = slot.flatCenter
        let p = CurlFunction.deform(position: c, normal: up, params: params).position
        let pu = CurlFunction.deform(position: c + SIMD3<Float>(eps, 0, 0), normal: up, params: params).position
        let pv = CurlFunction.deform(position: c + SIMD3<Float>(0, eps, 0), normal: up, params: params).position

        let tu = normalizeSafe(pu - p, fallback: SIMD3<Float>(1, 0, 0))
        let tv = normalizeSafe(pv - p, fallback: SIMD3<Float>(0, 1, 0))
        let n = normalizeSafe(cross(tu, tv), fallback: SIMD3<Float>(0, 0, 1))

        // Front: card local (x,y,z) -> (tu, tv, n) so +z faces outward front.
        // Back: face outward on the back side (-n), mirror x to keep art upright.
        let basis: float3x3
        if slot.side == .front {
            basis = float3x3(tu, tv, n)
        } else {
            basis = float3x3(-tu, tv, -n)
        }
        card.orientation = simd_quatf(basis)
        card.position = p
    }

    private static func normalizeSafe(_ v: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let len = length(v)
        return len > 1e-6 ? v / len : fallback
    }
}

// MARK: - Spawn / despawn coordinator

@MainActor
final class CardPlacement {
    private static let log = Logger(subsystem: "com.aja.binderBuilder", category: "CardPlacement")

    private let provider: any CardContentProviding
    private let textures: CardTextureCache

    init(provider: any CardContentProviding, textures: CardTextureCache) {
        self.provider = provider
        self.textures = textures
    }

    /// onRebound handler: `pages` lists every pool entity with the sheet it now
    /// represents (nil = disabled, clear its cards).
    func rebound(_ pages: [(entity: ModelEntity, sheet: Int?)]) {
        for (entity, sheet) in pages {
            guard let sheet else { clearCards(on: entity); continue }
            let snap = provider.snapshot(sheet: sheet)
            sync(page: entity, side: .front, desired: snap.front)
            sync(page: entity, side: .back, desired: snap.back)
        }
    }

    private func clearCards(on page: ModelEntity) {
        for child in page.children where child.components.has(CardSlotComponent.self) {
            child.removeFromParent()
        }
    }

    private func sync(page: ModelEntity, side: PageSide, desired: [CardSlotRender?]) {
        // Index existing card children for this side by slot.
        var existing: [Int: ModelEntity] = [:]
        for child in page.children {
            guard let slot = child.components[CardSlotComponent.self], slot.side == side,
                  let model = child as? ModelEntity else { continue }
            existing[slot.slot] = model
        }

        for slot in 0..<SpreadModel.slotsPerPage {
            let want = desired[slot]
            let have = existing[slot]

            switch (want, have) {
            case (nil, nil):
                continue
            case (nil, .some(let entity)):
                entity.removeFromParent()
            case (.some(let render), .some(let entity)):
                if entity.components[CardSlotComponent.self]?.ref == render.ref {
                    CardFactory.setOwnership(entity, owned: render.owned, variant: render.ref.variant)
                } else {
                    entity.removeFromParent()
                    spawn(render, slot: slot, side: side, on: page)
                }
            case (.some(let render), nil):
                spawn(render, slot: slot, side: side, on: page)
            }
        }
    }

    private func spawn(_ render: CardSlotRender, slot: Int, side: PageSide, on page: ModelEntity) {
        let initial = textures.cached(render.ref) ?? textures.placeholder
        guard let card = CardFactory.makeCard(
            ref: render.ref, slot: slot, side: side, owned: render.owned, texture: initial
        ) else { return }
        if textures.cached(render.ref) != nil {
            if var comp = card.components[CardSlotComponent.self] { comp.hasArt = true; card.components.set(comp) }
        }
        page.addChild(card)
        loadArt(into: card, render: render)
    }

    private func loadArt(into card: ModelEntity, render: CardSlotRender) {
        if card.components[CardSlotComponent.self]?.hasArt == true { return }
        Task { [weak card, textures] in
            guard let texture = try? await textures.load(render.ref, imageBase: render.imageBase, pinned: render.owned),
                  let card, var comp = card.components[CardSlotComponent.self], comp.ref == render.ref
            else { return }
            CardFactory.updateFront(card, texture: texture, variant: render.ref.variant, owned: render.owned)
            comp.hasArt = true
            card.components.set(comp)
        }
    }
}
