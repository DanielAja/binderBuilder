//
//  BinderCardContent.swift
//  binderBuilder
//
//  The production card content source for the 3D scene: snapshots a binder's
//  SpreadModels (from BinderStore, MainActor + async) into a plain Sendable
//  per-sheet array the nonisolated scene layer can read synchronously each
//  rebind. Built once when a binder opens; rebuilt when its contents change.
//

import simd

/// Immutable, Sendable card content for one binder. Conforms to
/// CardContentProviding so it also supplies the flip dynamics' occupancy.
nonisolated struct BinderCardContent: CardContentProviding {
    let sheetCount: Int
    let snapshots: [SheetCardSnapshot]

    func snapshot(sheet: Int) -> SheetCardSnapshot {
        guard (0..<sheetCount).contains(sheet) else { return .empty }
        return snapshots[sheet]
    }

    static let empty = BinderCardContent(sheetCount: 0, snapshots: [])
}

@MainActor
enum BinderCardContentBuilder {
    /// Reads every spread of `binderID` and reassembles per-sheet snapshots.
    /// A binder with N sheets has N+1 spreads; spread s shows sheet s's front
    /// on the right and sheet (s-1)'s back on the left.
    static func build(binderID: String, store: BinderStore) async -> BinderCardContent {
        let sheetCount = max(0, store.spreadCount(binderID: binderID) - 1)
        guard sheetCount > 0 else { return .empty }

        let empty = [CardSlotRender?](repeating: nil, count: SpreadModel.slotsPerPage)
        var fronts = Array(repeating: empty, count: sheetCount)
        var backs = Array(repeating: empty, count: sheetCount)

        for spread in 0...sheetCount {
            guard let model = try? await store.spread(spread, in: binderID) else { continue }
            if spread < sheetCount {
                fronts[spread] = model.right.map(render)
            }
            let backSheet = spread - 1
            if backSheet >= 0, backSheet < sheetCount {
                backs[backSheet] = model.left.map(render)
            }
        }

        let snapshots = (0..<sheetCount).map {
            SheetCardSnapshot(front: fronts[$0], back: backs[$0])
        }
        return BinderCardContent(sheetCount: sheetCount, snapshots: snapshots)
    }

    private static func render(_ content: SlotContent?) -> CardSlotRender? {
        guard let content else { return nil }
        return CardSlotRender(
            ref: CardRef(cardID: content.card.id, variant: content.variant),
            imageBase: content.card.imageBase,
            owned: content.owned
        )
    }
}
