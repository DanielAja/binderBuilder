//
//  PagePool.swift
//  binderBuilder
//
//  Pure math for the 4-entity page pool: which physical sheets are bound
//  around a given spread, which pool slot a sheet maps to, and where each
//  bound sheet rests. Kept nonisolated + entity-free so it is unit-testable.
//
//  Spread model (see BinderModels.SpreadModel): a binder with N sheets has
//  N+1 spreads. At spread s, sheets 0..<s lie on the LEFT stack (flipped,
//  showing their backs) and sheets s..<N on the RIGHT stack (showing their
//  fronts). A forward flip turns sheet s (right top); a backward flip turns
//  sheet s-1 (left top).
//
//  The pool binds the four sheets s-2, s-1, s, s+1 (clamped to the binder):
//  the two turnable sheets plus the sheet revealed beneath each of them.
//  Sheets map to pool entities by sheet % 4, so any window of 4 consecutive
//  sheets uses 4 distinct entities AND a sheet keeps its entity (and thus its
//  deformer state) across neighboring spreads — the turning page is never
//  re-created mid-interaction.
//

import Foundation

nonisolated enum PagePool {
    static let capacity = 4

    /// Sheets that should have live deformable page entities at `spread`.
    static func boundSheets(spread: Int, sheetCount: Int) -> [Int] {
        guard sheetCount > 0 else { return [] }
        let lo = max(0, spread - 2)
        let hi = min(sheetCount - 1, spread + 1)
        guard lo <= hi else { return [] }
        return Array(lo...hi)
    }

    /// Stable pool-entity index for a sheet.
    static func poolSlot(forSheet sheet: Int) -> Int {
        precondition(sheet >= 0)
        return sheet % capacity
    }

    /// Rest curl progress: 0 = flat on the right stack, 1 = flat on the left.
    static func restProgress(sheet: Int, spread: Int) -> Float {
        sheet < spread ? 1 : 0
    }

    /// 0 = top of its stack, 1 = directly beneath, ...
    static func stackLayer(sheet: Int, spread: Int) -> Int {
        sheet < spread ? spread - 1 - sheet : sheet - spread
    }

    static func sheetsOnLeft(spread: Int) -> Int { max(0, spread) }

    static func sheetsOnRight(spread: Int, sheetCount: Int) -> Int {
        max(0, sheetCount - max(0, spread))
    }
}
