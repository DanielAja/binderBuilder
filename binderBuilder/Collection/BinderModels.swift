//
//  BinderModels.swift
//  binderBuilder
//
//  Value types shared between the data layer and the 3D scene:
//  Binder, PageSide, SlotLocation, SlotContent, SpreadModel.
//

import Foundation

nonisolated struct Binder: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    /// Cover color as a hex string, e.g. "#1B6CA8".
    var coverColor: String
    /// Number of physical sheets in the binder (each sheet has a front and
    /// a back side of 9 pockets).
    var pageCount: Int
    var sortOrder: Int
}

/// Which side of a physical sheet a pocket page is on.
/// Raw values match `slot_assignment.side` (0 = front, 1 = back).
nonisolated enum PageSide: Int, Codable, Sendable, Hashable, CaseIterable {
    /// Visible while the sheet still lies on the RIGHT stack.
    case front = 0
    /// Visible after the sheet has been flipped onto the LEFT stack.
    case back = 1
}

/// Addresses one pocket: (binder, physical sheet, side, 0..8 row-major).
nonisolated struct SlotLocation: Hashable, Sendable {
    var binderID: String
    /// Physical sheet index, 0-based.
    var pageIndex: Int
    var side: PageSide
    /// 0..8, row-major within the 3x3 pocket grid.
    var slotIndex: Int
}

/// What a pocket displays: the card, the chosen variant, and whether the
/// user owns that exact printing (unowned renders grayscale in 3D).
nonisolated struct SlotContent: Equatable, Sendable {
    var card: CardSummary
    var variant: CardVariant
    var owned: Bool
}

/// One open spread of a binder — the contract the 3D layer renders from.
///
/// Physical model: a binder with `pageCount == N` holds N sheets. Sheet s
/// shows its FRONT (side 0) while it is on the right stack and its BACK
/// (side 1) once flipped to the left stack. Opening the binder to spread s
/// (0...N, so N+1 spreads in total) you therefore see:
///
///     left page  = sheet (s-1)'s BACK   — absent for s == 0
///                                         (nothing flipped yet; you face
///                                          the inside cover + sheet 0)
///     right page = sheet s's FRONT      — absent for s == N
///                                         (all sheets flipped; inside of
///                                          the back cover)
///
/// Example, N = 2:  spread 0: [cover | sheet0.front]
///                  spread 1: [sheet0.back | sheet1.front]
///                  spread 2: [sheet1.back | cover]
nonisolated struct SpreadModel: Equatable, Sendable {
    static let slotsPerPage = 9

    /// Exactly 9 entries (3x3, row-major). All nil for a cover page.
    let left: [SlotContent?]
    /// Exactly 9 entries (3x3, row-major). All nil for a cover page.
    let right: [SlotContent?]

    static let empty = SpreadModel(
        left: Array(repeating: nil, count: slotsPerPage),
        right: Array(repeating: nil, count: slotsPerPage))

    init(left: [SlotContent?], right: [SlotContent?]) {
        precondition(left.count == Self.slotsPerPage && right.count == Self.slotsPerPage,
                     "SpreadModel pages must have exactly \(Self.slotsPerPage) slots")
        self.left = left
        self.right = right
    }
}
