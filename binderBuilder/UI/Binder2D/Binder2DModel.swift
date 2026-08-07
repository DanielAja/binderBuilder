//
//  Binder2DModel.swift
//  binderBuilder
//
//  View model for the 2D binder editor: page-side render models built from
//  BinderStore spreads, a bounded undo stack of whole-binder snapshots, and
//  the pure move-preview math the drag gesture animates with before a drop
//  commits the authoritative BinderStore.moveCard.
//

import Foundation
import Observation

@MainActor @Observable final class Binder2DModel {
    /// One side of one physical sheet — the unit the 2D editor scrolls.
    struct PageSideModel: Identifiable, Equatable {
        let pageIndex: Int
        let side: PageSide
        /// Exactly 9 entries, row-major.
        var slots: [SlotContent?]

        var id: String { "\(pageIndex)-\(side.rawValue)" }
        var title: String { "Page \(pageIndex + 1) · \(side == .front ? "Front" : "Back")" }
    }

    private let store: BinderStore
    let binderID: String

    private(set) var pages: [PageSideModel] = []
    /// The changeToken `pages` was built from (−1 = never loaded).
    private(set) var loadedToken = -1
    private(set) var isLoading = false

    /// Whole-binder snapshots taken before each mutation, newest last.
    private var undoStack: [[SlotAssignmentRow]] = []
    private static let undoDepth = 10
    var canUndo: Bool { !undoStack.isEmpty }

    var binder: Binder? { store.binders.first(where: { $0.id == binderID }) }

    init(store: BinderStore, binderID: String) {
        self.store = store
        self.binderID = binderID
    }

    // MARK: - Loading

    func reloadIfNeeded() async {
        guard store.changeToken != loadedToken else { return }
        await reload()
    }

    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let token = store.changeToken
        guard let binder else {
            pages = []
            loadedToken = token
            return
        }
        var fronts: [[SlotContent?]] = Array(
            repeating: Array(repeating: nil, count: SpreadModel.slotsPerPage),
            count: binder.pageCount)
        var backs = fronts
        for spread in 0...binder.pageCount {
            guard let model = try? await store.spread(spread, in: binderID) else { continue }
            if spread < binder.pageCount { fronts[spread] = model.right }
            if spread > 0 { backs[spread - 1] = model.left }
        }
        pages = (0..<binder.pageCount).flatMap { sheet in
            [PageSideModel(pageIndex: sheet, side: .front, slots: fronts[sheet]),
             PageSideModel(pageIndex: sheet, side: .back, slots: backs[sheet])]
        }
        loadedToken = token
    }

    // MARK: - Mutations (undo-snapshotted; observers reload via changeToken)

    /// Puts `ref` in `slot`, replacing any occupant.
    @discardableResult
    func fill(_ slot: SlotLocation, with ref: CardRef) -> Bool {
        snapshotForUndo()
        guard store.setSlot(ref, at: slot) else { discardLastUndo(); return false }
        return true
    }

    @discardableResult
    func remove(at slot: SlotLocation) -> Bool {
        snapshotForUndo()
        guard store.clearSlot(slot) else { discardLastUndo(); return false }
        return true
    }

    func move(from: SlotLocation, to: SlotLocation, mode: SlotMoveMode) -> MoveResult? {
        snapshotForUndo()
        guard let result = store.moveCard(from: from, to: to, mode: mode) else {
            discardLastUndo()
            return nil
        }
        return result
    }

    @discardableResult
    func undo() -> Bool {
        guard let snapshot = undoStack.popLast() else { return false }
        return store.restoreAssignments(snapshot, binderID: binderID)
    }

    // MARK: - Page ops
    //
    // Not undo-snapshotted: an assignments snapshot can't restore a page
    // count, so undoing across a page op would strand rows. The stack clears
    // instead, and remove is confirmed in the UI.

    @discardableResult
    func addPage() -> Bool {
        undoStack.removeAll()
        return store.addPages(1, to: binderID)
    }

    @discardableResult
    func insertPage(at pageIndex: Int) -> Bool {
        undoStack.removeAll()
        return store.insertPage(at: pageIndex, in: binderID)
    }

    @discardableResult
    func removePage(at pageIndex: Int) -> Bool {
        undoStack.removeAll()
        return store.removePage(at: pageIndex, from: binderID)
    }

    /// Cards on sheet `pageIndex` (both sides), for the remove confirmation.
    func assignmentCount(pageIndex: Int) -> Int {
        store.assignmentCount(binderID: binderID, pageIndex: pageIndex)
    }

    private func snapshotForUndo() {
        undoStack.append(store.assignments(binderID: binderID))
        if undoStack.count > Self.undoDepth { undoStack.removeFirst() }
    }

    private func discardLastUndo() {
        _ = undoStack.popLast()
    }

    // MARK: - Slot addressing

    func location(page: PageSideModel, index: Int) -> SlotLocation {
        SlotLocation(binderID: binderID, pageIndex: page.pageIndex, side: page.side, slotIndex: index)
    }

    // MARK: - Move preview (pure)

    /// Flattens the page sides into one ordinal-indexed slot array (the same
    /// order `BinderStore.ordinal` uses).
    nonisolated static func flattened(_ pages: [PageSideModel]) -> [SlotContent?] {
        // Pages arrive as front, back per sheet — already ordinal order.
        pages.flatMap(\.slots)
    }

    /// The visual result of `moveCard` on a flat slot array — mirrors the
    /// store's semantics (including the gap-absorbing ripple) so the drag
    /// preview animates exactly what the drop will commit. Returns nil when
    /// the move would be refused.
    nonisolated static func applyMovePreview(
        _ slots: [SlotContent?], from: Int, to: Int, mode: SlotMoveMode
    ) -> [SlotContent?]? {
        guard slots.indices.contains(from), slots.indices.contains(to), from != to,
              let moved = slots[from] else { return nil }
        var result = slots
        result[from] = nil
        switch mode {
        case .swap:
            result[from] = result[to]
            result[to] = moved
        case .insertShift:
            var carry: SlotContent? = moved
            var index = to
            while let occupant = result[index] {
                result[index] = carry
                carry = occupant
                index += 1
                guard result.indices.contains(index) else { return nil }
            }
            result[index] = carry
        }
        return result
    }

    /// Re-chunks a flattened preview back into the current page structure.
    nonisolated static func rechunk(
        _ slots: [SlotContent?], like pages: [PageSideModel]
    ) -> [PageSideModel] {
        var rebuilt = pages
        var cursor = 0
        for index in rebuilt.indices {
            let width = rebuilt[index].slots.count
            rebuilt[index].slots = Array(slots[cursor..<min(cursor + width, slots.count)])
            cursor += width
        }
        return rebuilt
    }
}
