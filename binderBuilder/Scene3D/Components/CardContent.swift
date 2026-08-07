//
//  CardContent.swift
//  binderBuilder
//
//  The seam between the data layer (BinderStore / SpreadModel) and the 3D card
//  rendering. A `CardContentProviding` hands the scene plain, Sendable
//  per-sheet snapshots; BinderCardContentSource builds them from BinderStore,
//  DebugCardContentSource fabricates them from real catalog IDs for
//  standalone scene verification. The provider also conforms to
//  PageContentSource so the flip dynamics (mass/sag) stay driven by the same
//  truth as the rendered cards.
//

import simd

/// Everything the 3D layer needs to render one occupied pocket.
nonisolated struct CardSlotRender: Equatable, Sendable {
    var ref: CardRef
    /// TCGdex `image_base` (e.g. "en/base/base1/4"); nil -> placeholder back.
    var imageBase: String?
    /// Unowned cards render grayscale (a shader uniform), owned in full color.
    var owned: Bool
    /// Raw TCGdex rarity string from the catalog; nil when unknown. Keys the
    /// foil effect together with `ref.variant` (see FoilTier).
    var rarity: String?

    init(ref: CardRef, imageBase: String?, owned: Bool, rarity: String? = nil) {
        self.ref = ref
        self.imageBase = imageBase
        self.owned = owned
        self.rarity = rarity
    }

    /// Which shader foil branch this printing gets.
    var foil: FoilTier { FoilTier.resolve(rarity: rarity, variant: ref.variant) }
}

/// One physical sheet's pockets: 9 front + 9 back, slot-major, nil = empty.
nonisolated struct SheetCardSnapshot: Equatable, Sendable {
    var front: [CardSlotRender?]
    var back: [CardSlotRender?]

    static let empty = SheetCardSnapshot(
        front: Array(repeating: nil, count: 9),
        back: Array(repeating: nil, count: 9)
    )

    func side(_ side: PageSide) -> [CardSlotRender?] {
        side == .front ? front : back
    }

    /// Occupancy bitmask for one side (bits 0...8, slot-major).
    func occupiedMask(_ side: PageSide) -> UInt16 {
        var mask: UInt16 = 0
        for (slot, content) in self.side(side).enumerated() where content != nil {
            mask |= (1 << UInt16(slot))
        }
        return mask
    }
}

/// Source of card content per physical sheet. Conforms to PageContentSource so
/// the existing flip dynamics read occupancy from the same snapshots.
nonisolated protocol CardContentProviding: PageContentSource {
    /// Snapshot for a sheet. Out-of-range sheets return `.empty`.
    func snapshot(sheet: Int) -> SheetCardSnapshot
}

nonisolated extension CardContentProviding {
    func occupiedSlots(sheet: Int, side: PageSide) -> UInt16 {
        snapshot(sheet: sheet).occupiedMask(side)
    }
}

// MARK: - Page-local slot geometry

/// Where a card sits on a page, in page-local mesh space (x from spine 0...width,
/// y 0...height, +z front normal) — the same space CurlFunction deforms, so a
/// card posed here rides the curl exactly.
nonisolated enum CardSlotGeometry {
    /// Card center distance off the page plane. Seated just ABOVE the sleeve
    /// film (SleeveGeometry.surfaceOffset = 0.7 mm) so the translucent pocket
    /// reads as the card's backing/border without depth-occluding the art
    /// (the film is a submesh of the page entity; cross-entity transparency
    /// sorting would otherwise hide a card nestled beneath it).
    static let cardZ: Float = 0.0012

    /// Page-local center of a pocket for a given side. Back-side slot indices
    /// are mirrored in column (top-left as seen from the BACK is page-local
    /// top-right), matching how the binder's back pockets read.
    static func center(slot: Int, side: PageSide) -> SIMD3<Float> {
        let physical = physicalSlot(slot: slot, side: side)
        let origin = SleeveGeometry.pocketOrigin(slot: physical)
        let cx = origin.x + SleeveGeometry.pocketWidth / 2
        let cy = origin.y + SleeveGeometry.pocketHeight / 2
        let z: Float = side == .front ? cardZ : -cardZ
        return SIMD3<Float>(cx, cy, z)
    }

    static func physicalSlot(slot: Int, side: PageSide) -> Int {
        switch side {
        case .front:
            return slot
        case .back:
            let row = slot / 3
            let col = slot % 3
            return row * 3 + (2 - col)
        }
    }
}

// MARK: - Debug provider

/// Standalone scene content: lays a handful of real TCGdex cards into the
/// middle spreads so the 3D card path can be screenshot-verified before the
/// BinderStore-backed source and DemoSeed are wired (Phase W). Even sheets
/// carry color (owned) cards on the front; odd sheets carry grayscale
/// (unowned) cards on the back, so a single spread shows both states.
nonisolated struct DebugCardContentSource: CardContentProviding {
    let sheetCount: Int
    private let cards: [CardSlotRender]

    init(sheetCount: Int = 10) {
        self.sheetCount = sheetCount
        // Real TCGdex IDs + image bases ("en/<serie>/<set>/<localId>"), one per
        // foil tier so a single debug spread exercises every shader branch.
        let ids: [(String, String, String?, CardVariant)] = [
            ("base1-4", "en/base/base1/4", "Rare", .holo),                            // holoArt
            ("base1-58", "en/base/base1/58", "Common", .reverse),                     // reverseInverse
            ("swsh12-139", "en/swsh/swsh12/139", "Holo Rare VSTAR", .holo),           // fullArtEtched
            ("sv02-196", "en/sv/sv02/196", "Illustration rare", .holo),               // illustrationRare
            ("sv04-245", "en/sv/sv04/245", "Special illustration rare", .holo),       // SIR
            ("swsh4-198", "en/swsh/swsh4/198", "Secret Rare", .holo),                 // secretRainbow
            ("sv03-229", "en/sv/sv03/229", "Hyper rare", .holo),                      // goldHyper
            ("me02-130", "en/me/me02/130", "Mega Hyper Rare", .holo),                 // megaHyperGold
            ("base1-46", "en/base/base1/46", "Common", .normal),                      // none
        ]
        cards = ids.map {
            CardSlotRender(
                ref: CardRef(cardID: $0.0, variant: $0.3),
                imageBase: $0.1,
                owned: true,
                rarity: $0.2
            )
        }
    }

    func snapshot(sheet: Int) -> SheetCardSnapshot {
        guard (0..<sheetCount).contains(sheet) else { return .empty }
        var snap = SheetCardSnapshot.empty
        // Spread `sheet` shows sheet.front on the right; fill a few front slots.
        let owned = sheet % 2 == 0
        let count = (sheet % 3) + 4 // 4...6 cards
        for slot in 0..<min(count, 9) {
            var card = cards[slot]
            card.owned = owned
            snap.front[slot] = card
        }
        // And some back slots so the left page of the next spread has content.
        for slot in 0..<min((sheet % 4) + 2, 9) {
            // Offset by 4 so front (0...5) and back (4...8) between them touch
            // every card — i.e. every foil tier — across the debug sheets.
            var card = cards[(slot + 4) % cards.count]
            card.owned = !owned
            snap.back[slot] = card
        }
        return snap
    }
}
