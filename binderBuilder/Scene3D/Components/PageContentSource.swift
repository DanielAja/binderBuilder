//
//  PageContentSource.swift
//  binderBuilder
//
//  Abstracts "what's in the binder" for the 3D page layer: how many physical
//  sheets exist and which of the 9 pockets on each side are occupied.
//  Occupancy drives the flip feel (heavier pages flip slower and sag more)
//  and, in the next phase, which pockets get card entities. BinderStore will
//  provide the real implementation; DebugPageContentSource feeds the scene
//  deterministic content until then.
//

import Foundation

nonisolated protocol PageContentSource {
    /// Number of physical sheets (each has a front and a back side).
    var sheetCount: Int { get }
    /// Bitmask of occupied pockets for one side of a sheet: bits 0...8,
    /// row-major within the 3x3 grid. Out-of-range sheets return 0.
    func occupiedSlots(sheet: Int, side: PageSide) -> UInt16
}

extension PageContentSource {
    /// Occupied pockets across BOTH sides of a sheet (0...18) — the "mass"
    /// of the turning sheet.
    func occupiedCount(sheet: Int) -> Int {
        occupiedSlots(sheet: sheet, side: .front).nonzeroBitCount
            + occupiedSlots(sheet: sheet, side: .back).nonzeroBitCount
    }
}

/// Deterministic debug content: 10 sheets with varied occupancy so flips
/// feel different page to page. Sheet i's FRONT has (i*3) % 10 occupied
/// pockets and its BACK has (i*7 + 4) % 10, filled row-major from slot 0.
nonisolated struct DebugPageContentSource: PageContentSource {
    let sheetCount: Int

    init(sheetCount: Int = 10) {
        self.sheetCount = sheetCount
    }

    func occupiedSlots(sheet: Int, side: PageSide) -> UInt16 {
        guard (0..<sheetCount).contains(sheet) else { return 0 }
        let count: Int
        switch side {
        case .front: count = (sheet * 3) % 10
        case .back: count = (sheet * 7 + 4) % 10
        }
        let capped = min(count, 9)
        return UInt16((1 << capped) - 1)
    }
}
