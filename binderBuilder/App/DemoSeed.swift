//
//  DemoSeed.swift
//  binderBuilder
//
//  First-run content so the app opens onto a real binder instead of an empty
//  one: marks roughly half of the Base Set as owned and lays the set into a
//  demo binder (a mix of owned/unowned across both sides of several sheets).
//  Idempotent — gated by SettingsStore.demoSeeded, so it runs exactly once.
//
//  The two pages the scene actually opens to are a SHOWCASE spread: one card
//  per FoilTier, spliced into the layout so the first thing a new install
//  shows is the full range of foil treatments rather than eighteen commons.
//

import Foundation

@MainActor
enum DemoSeed {
    static let demoSetID = "base1"
    static let demoBinderName = "Base Set"

    /// Seeds the demo collection + binder on first launch. Safe to call every
    /// launch; returns immediately once seeded.
    static func seedIfNeeded(
        settings: SettingsStore,
        catalog: (any CatalogReading)?,
        collection: CollectionStore,
        binders: BinderStore
    ) async {
        guard !settings.demoSeeded else { return }
        guard let catalog,
              let setCards = try? await catalog.cards(inSet: demoSetID),
              !setCards.isEmpty else { return }

        let showcase = await showcaseCards(catalog: catalog)
        let showcaseIDSet = Set(showcase.map(\.id))
        let base = setCards.filter { !showcaseIDSet.contains($0.id) }

        // A sheet holds 18 cards (9 per side); the scene opens on the middle
        // spread, whose two visible pages are the BACK of sheet (mid - 1) and
        // the FRONT of sheet mid — layout indices [18*mid - 9, 18*mid + 9).
        var layout = base
        let plan = ShowcasePlan(baseCount: base.count, showcaseCount: showcase.count)
        let pageCount = plan.pageCount
        layout.insert(contentsOf: showcase, at: min(plan.spliceIndex, layout.count))

        // Own every other card so a single spread shows color + grayscale —
        // but never a showcase card, whose foil is the whole point.
        for (index, card) in layout.enumerated() where index % 2 == 0 || showcaseIDSet.contains(card.id) {
            collection.setOwned(CardRef(cardID: card.id, variant: variant(for: card)), quantity: 1)
        }

        guard let binder = binders.createBinder(
            name: demoBinderName, coverColor: "#1B6CA8", pageCount: pageCount
        ) else { return }

        var index = 0
        outer: for page in 0..<pageCount {
            for side in [PageSide.front, .back] {
                for slot in 0..<SpreadModel.slotsPerPage {
                    guard index < layout.count else { break outer }
                    let card = layout[index]
                    index += 1
                    binders.assign(
                        CardRef(cardID: card.id, variant: variant(for: card)),
                        to: SlotLocation(binderID: binder.id, pageIndex: page, side: side, slotIndex: slot)
                    )
                }
            }
        }

        settings.demoSeeded = true
    }

    /// Where the showcase run has to sit in the flat card layout for it to land
    /// on the spread the scene actually opens to. Pure so the arithmetic — the
    /// fragile part of the whole seed — is testable without a catalog.
    ///
    /// Cards are laid out flat, 18 per sheet (front slots 0...8 then back slots
    /// 0...8), and `BinderSceneView` opens at spread `sheetCount / 2`. A spread
    /// shows the BACK of sheet (mid - 1) on the left and the FRONT of sheet
    /// `mid` on the right, i.e. flat indices `[18*mid - 9, 18*mid + 9)`.
    nonisolated struct ShowcasePlan: Equatable {
        /// Sheets in the demo binder.
        let pageCount: Int
        /// Index in the flat layout to insert the showcase run at.
        let spliceIndex: Int
        /// The spread the scene opens on.
        let openingSpread: Int

        /// Flat-layout indices visible on the opening spread.
        var visibleRange: Range<Int> {
            let perSheet = SpreadModel.slotsPerPage * 2
            return (perSheet * openingSpread - SpreadModel.slotsPerPage)
                ..< (perSheet * openingSpread + SpreadModel.slotsPerPage)
        }

        init(baseCount: Int, showcaseCount: Int) {
            let perSheet = SpreadModel.slotsPerPage * 2
            pageCount = max(2, min(8, (baseCount + showcaseCount + perSheet - 1) / perSheet))
            openingSpread = pageCount / 2
            spliceIndex = max(SpreadModel.slotsPerPage * (2 * openingSpread - 1), 0)
        }
    }

    /// The showcase run: two real cards per foil tier, ordered flat -> gold, so
    /// the demo binder's opening spread differentiates every shader branch
    /// side by side. Exactly 18 entries, which is exactly one spread.
    ///
    /// `tier` is the treatment the entry exists to demonstrate — it is NOT read
    /// at runtime (the real tier is resolved from the catalog's rarity string +
    /// printing via `FoilTier.resolve`), it is the claim the coverage test
    /// checks, so "one card per tier" can't silently rot as IDs are swapped.
    /// IDs are resolved through the catalog, so an entry missing from a future
    /// catalog build drops out instead of seeding a broken slot.
    static let showcase: [(id: String, tier: FoilTier)] = [
        ("swsh3-24", .holoArt),                     // Holo Rare
        ("swsh10-046", .holoArt),                   // Radiant Rare
        ("swsh6-69", .reverseInverse),              // Common, reverse only
        ("swsh4-26", .reverseInverse),              // Rare, reverse only
        ("swsh12-139", .fullArtEtched),             // Holo Rare VSTAR
        ("sv09-069", .fullArtEtched),               // Double rare
        ("sv09-170", .illustrationRare),            // Illustration rare
        ("sv02-196", .illustrationRare),            // Illustration rare
        ("sv04-245", .specialIllustrationRare),     // Special illustration rare
        ("sv08.5-161", .specialIllustrationRare),   // Special illustration rare
        ("swsh4-198", .secretRainbow),              // Secret Rare
        ("swsh11-200", .secretRainbow),             // Secret Rare
        ("sv03-229", .goldHyper),                   // Hyper rare
        ("sv01-254", .goldHyper),                   // Hyper rare
        ("me02-130", .megaHyperGold),               // Mega Hyper Rare
        ("me03-124", .megaHyperGold),               // Mega Hyper Rare
        ("swsh12-TG26", .illustrationRare),         // Full Art Trainer
        ("sv06-163", .illustrationRare)             // ACE SPEC Rare
    ]

    static var showcaseIDs: [String] { showcase.map(\.id) }

    private static func showcaseCards(catalog: any CatalogReading) async -> [CardSummary] {
        let showcaseIDs = Self.showcaseIDs
        guard let found = try? await catalog.summaries(forCardIDs: showcaseIDs) else { return [] }
        let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return showcaseIDs.compactMap { byID[$0] }
    }

    /// Prefer the flashiest available printing for the demo foils.
    private static func variant(for card: CardSummary) -> CardVariant {
        for preferred in [CardVariant.holo, .reverse, .firstEdition, .normal]
        where card.availableVariants.contains(preferred) {
            return preferred
        }
        return .normal
    }
}
