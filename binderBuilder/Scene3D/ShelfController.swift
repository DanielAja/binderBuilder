//
//  ShelfController.swift
//  binderBuilder
//
//  Keeps the shelf's data-driven rows in sync with the stores: one standing
//  binder per stored Binder (tinted + labeled), and the display cases with
//  their cards. Rebuilds are cheap (a handful of USDZ clones), so refreshes
//  just tear down and rebuild each row; card art loads async through the
//  shared CardTextureCache with the placeholder showing first — the same
//  placeholder-then-art flow the binder pockets use.
//

import OSLog
import RealityKit
import simd

@MainActor
final class ShelfController {
    private static let log = Logger(subsystem: "com.aja.binderBuilder", category: "ShelfController")

    private let binderRow: Entity
    private let displayRow: Entity
    private let textures: CardTextureCache

    // Templates load once and clone per item.
    private lazy var binderTemplate = ShelfSceneBuilder.loadBinderTemplate()
    private lazy var caseTemplate = ShelfSceneBuilder.loadCaseTemplate()
    private lazy var standTemplate = ShelfSceneBuilder.loadStandTemplate()

    private(set) var binderEntities: [String: Entity] = [:]
    /// Rest transforms, for restoring a binder after its pull-out animation.
    private var binderRestTransforms: [String: Transform] = [:]
    /// Bumped per display refresh so stale async art loads drop out.
    private var displayGeneration = 0
    /// Highest `requestID` applied by `refreshDisplayCases`, so an out-of-order
    /// snapshot can be dropped. Callers get their ids from `nextDisplayRequest`.
    private var appliedDisplayRequest = -1
    private var issuedDisplayRequests = 0

    /// Ticket for a display-case read that is about to start. Hand the returned
    /// id to `refreshDisplayCases` when the read completes.
    func nextDisplayRequest() -> Int {
        issuedDisplayRequests += 1
        return issuedDisplayRequests
    }

    /// What the rows were last built from — refreshes are skipped when
    /// nothing changed (the Binder tab re-appears often).
    private var builtBinders: [Binder] = []
    private var builtOpenID: String?
    private var builtContents: [SlotContent?]?

    init(binderRow: Entity, displayRow: Entity, textures: CardTextureCache) {
        self.binderRow = binderRow
        self.displayRow = displayRow
        self.textures = textures
    }

    // MARK: - Binder row

    func refreshBinders(_ binders: [Binder], openBinderID: String?) {
        guard binders != builtBinders || openBinderID != builtOpenID else { return }
        builtBinders = binders
        builtOpenID = openBinderID

        // `children` is a live view of the parent: removing while iterating it
        // advances the index past the entity that slid down into the vacated
        // slot, so a plain forEach leaves half the row behind — ghost binders
        // z-fighting at the same coordinates, with live tap colliders that can
        // resolve to a deleted binder's id.
        binderRow.children.removeAll()
        binderEntities.removeAll()
        binderRestTransforms.removeAll()

        let openIndex = binders.firstIndex(where: { $0.id == openBinderID })
        let placements = ShelfLayout.binderPlacements(count: binders.count, openIndex: openIndex)
        for (binder, placement) in zip(binders, placements) {
            let entity = ShelfSceneBuilder.makeBinderEntity(
                binder, placement: placement, template: binderTemplate)
            binderRow.addChild(entity)
            binderEntities[binder.id] = entity
            binderRestTransforms[binder.id] = entity.transform
        }
        Self.log.info("Shelf binder row rebuilt: \(binders.count, privacy: .public) binders")
    }

    func binderEntity(id: String) -> Entity? {
        binderEntities[id]
    }

    /// Snaps a binder back to its shelf pose (after the pull-out animation,
    /// once the shelf root is hidden).
    func resetBinderPose(id: String) {
        guard let entity = binderEntities[id], let rest = binderRestTransforms[id] else { return }
        entity.transform = rest
    }

    // MARK: - Display row

    /// Applies a display-case snapshot. `requestID` orders concurrent callers:
    /// the contents are read asynchronously, so two quick edits can land out of
    /// order, and the older one would otherwise latch itself into
    /// `builtContents` — leaving the shelf showing the pre-edit card with the
    /// equality guard suppressing every later correction.
    func refreshDisplayCases(_ contents: [SlotContent?], maxCount: Int, requestID: Int) {
        guard requestID >= appliedDisplayRequest else { return }
        appliedDisplayRequest = requestID
        guard contents != builtContents else { return }
        builtContents = contents
        displayGeneration += 1
        let generation = displayGeneration

        displayRow.children.removeAll()   // see refreshBinders: never iterate-and-remove

        let xs = ShelfLayout.displayXs(count: contents.count, reserveAddSlot: contents.count < maxCount)
        for (index, x) in xs.enumerated() {
            let slot = ShelfSceneBuilder.makeDisplaySlot(
                index: index, x: x, caseTemplate: caseTemplate, standTemplate: standTemplate)
            displayRow.addChild(slot)
            if let content = contents[index] {
                spawnCard(content, in: slot, index: index, generation: generation)
            }
        }
        if let addX = ShelfLayout.addSlotX(count: contents.count, maxCount: maxCount) {
            displayRow.addChild(ShelfSceneBuilder.makeAddPedestal(x: addX))
        }
    }

    /// A real card entity on the stand: placeholder texture immediately, art
    /// swapped in when the cache delivers it. Holo/tilt comes free — the
    /// motion system drives every CardSlotComponent material.
    private func spawnCard(_ content: SlotContent, in slot: Entity, index: Int, generation: Int) {
        let ref = CardRef(cardID: content.card.id, variant: content.variant)
        let foil = FoilTier.resolve(rarity: content.card.rarity, variant: content.variant)
        guard let card = CardFactory.makeCard(
            ref: ref,
            slot: index,
            side: .front,
            owned: content.owned,
            texture: textures.cached(ref) ?? textures.placeholder,
            foil: foil)
        else { return }
        card.name = "DisplayCard\(index)"
        card.scale = SIMD3<Float>(repeating: ShelfSceneBuilder.cardScale)
        // Lean back against the stand's crossbar (matches its -16° legs).
        card.orientation = simd_quatf(angle: -0.28, axis: SIMD3<Float>(1, 0, 0))
        card.position = SIMD3<Float>(0, 0.072, 0.010)
        slot.addChild(card)

        let imageBase = content.card.imageBase
        let owned = content.owned
        Task { [weak self] in
            guard let self else { return }
            guard let texture = try? await self.textures.load(ref, imageBase: imageBase) else { return }
            // The row may have been rebuilt while the art downloaded.
            guard self.displayGeneration == generation, card.parent != nil else { return }
            CardFactory.updateFront(
                card, texture: texture, variant: ref.variant, owned: owned,
                foil: foil, artBoxEra: FoilTier.artBoxEra(cardID: ref.cardID))
        }
    }
}
