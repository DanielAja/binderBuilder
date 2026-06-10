//
//  DemoSeed.swift
//  binderBuilder
//
//  First-run content so the app opens onto a real binder instead of an empty
//  one: marks roughly half of the Base Set as owned and lays the set into a
//  demo binder (a mix of owned/unowned across both sides of several sheets).
//  Idempotent — gated by SettingsStore.demoSeeded, so it runs exactly once.
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
              let cards = try? await catalog.cards(inSet: demoSetID),
              !cards.isEmpty else { return }

        // Own every other card so a single spread shows color + grayscale.
        for (index, card) in cards.enumerated() where index % 2 == 0 {
            collection.setOwned(CardRef(cardID: card.id, variant: variant(for: card)), quantity: 1)
        }

        let pageCount = max(2, min(8, (cards.count + 17) / 18))
        guard let binder = binders.createBinder(
            name: demoBinderName, coverColor: "#1B6CA8", pageCount: pageCount
        ) else { return }

        var index = 0
        outer: for page in 0..<pageCount {
            for side in [PageSide.front, .back] {
                for slot in 0..<SpreadModel.slotsPerPage {
                    guard index < cards.count else { break outer }
                    let card = cards[index]
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

    /// Prefer the flashiest available printing for the demo foils.
    private static func variant(for card: CardSummary) -> CardVariant {
        for preferred in [CardVariant.holo, .reverse, .firstEdition, .normal]
        where card.availableVariants.contains(preferred) {
            return preferred
        }
        return .normal
    }
}
