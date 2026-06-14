//
//  BinderStore.swift
//  binderBuilder
//
//  Binders, slot assignments, and the shelf display case. Reads/writes
//  user.sqlite synchronously; resolves card metadata through an injected
//  CatalogReading (cached); resolves ownership through an injected closure
//  so it never couples to CollectionStore directly.
//

import Foundation
import GRDB
import Observation
import os

@MainActor @Observable final class BinderStore {
    private let database: UserDatabase
    /// nil when the app runs without a bundled catalog — spreads then render
    /// with empty pockets (assignments are preserved in the database).
    private let catalog: (any CatalogReading)?
    /// Ownership oracle, typically `collectionStore.isOwned`.
    private let isOwned: (CardRef) -> Bool

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.aja.binderBuilder", category: "BinderStore")

    /// All binders, ordered by sortOrder.
    private(set) var binders: [Binder] = []
    /// The 3 shelf display-case slots.
    private(set) var displayCase: [CardRef?] = [nil, nil, nil]

    /// CardSummary lookups are cached for the life of the store (the catalog
    /// is immutable).
    @ObservationIgnored private var summaryCache: [String: CardSummary] = [:]

    nonisolated static let displayCaseSlotCount = 3

    init(database: UserDatabase, catalog: (any CatalogReading)?, isOwned: @escaping (CardRef) -> Bool) {
        self.database = database
        self.catalog = catalog
        self.isOwned = isOwned
    }

    /// Loads binders + display case off the main thread (from prepare()), so a
    /// large library doesn't block the first frame.
    func load() async {
        struct Display: Sendable { let position: Int; let ref: CardRef }
        do {
            let loaded = try await database.queue.read { db -> ([Binder], [Display]) in
                let binders = try Row.fetchAll(db, sql: """
                    SELECT id, name, cover_color, page_count, sort_order
                    FROM binder ORDER BY sort_order
                    """).map { row in
                        Binder(id: row["id"], name: row["name"], coverColor: row["cover_color"],
                               pageCount: row["page_count"], sortOrder: row["sort_order"])
                    }
                let display = try Row.fetchAll(db, sql: "SELECT position, card_id, variant FROM display_case").compactMap { row -> Display? in
                    guard let position = row["position"] as Int?,
                          (0..<Self.displayCaseSlotCount).contains(position),
                          let variant = CardVariant(rawValue: row["variant"] as String? ?? "") else { return nil }
                    return Display(position: position, ref: CardRef(cardID: row["card_id"], variant: variant))
                }
                return (binders, display)
            }
            binders = loaded.0
            var slots: [CardRef?] = Array(repeating: nil, count: Self.displayCaseSlotCount)
            for item in loaded.1 { slots[item.position] = item.ref }
            displayCase = slots
        } catch {
            Self.logger.error("BinderStore load failed: \(String(describing: error))")
        }
    }

    /// First unoccupied slot in a binder (front-to-back, row-major), for
    /// quick "add to binder" placement. nil when the binder is full/unknown.
    func firstEmptySlot(binderID: String) -> SlotLocation? {
        guard let binder = binders.first(where: { $0.id == binderID }) else { return nil }
        let occupied: Set<[Int]> = (try? database.queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT page_index, side, slot_index FROM slot_assignment WHERE binder_id = ?",
                arguments: [binderID])
            return Set(rows.map { [$0["page_index"] as Int, $0["side"] as Int, $0["slot_index"] as Int] })
        }) ?? []
        for page in 0..<binder.pageCount {
            for side in [PageSide.front, .back] {
                for slot in 0..<SpreadModel.slotsPerPage where !occupied.contains([page, side.rawValue, slot]) {
                    return SlotLocation(binderID: binderID, pageIndex: page, side: side, slotIndex: slot)
                }
            }
        }
        return nil
    }

    // MARK: - Binder CRUD

    @discardableResult
    func createBinder(name: String, coverColor: String, pageCount: Int = 10) -> Binder? {
        let binder = Binder(
            id: UUID().uuidString,
            name: name,
            coverColor: coverColor,
            pageCount: pageCount,
            sortOrder: (binders.map(\.sortOrder).max() ?? -1) + 1)
        do {
            try database.queue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO binder (id, name, cover_color, page_count, sort_order, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [binder.id, binder.name, binder.coverColor, binder.pageCount,
                                binder.sortOrder, Date().timeIntervalSince1970])
            }
            binders.append(binder)
            return binder
        } catch {
            Self.logger.error("createBinder failed: \(String(describing: error))")
            return nil
        }
    }

    func renameBinder(_ binderID: String, to name: String) {
        guard let index = binders.firstIndex(where: { $0.id == binderID }) else { return }
        do {
            try database.queue.write { db in
                try db.execute(sql: "UPDATE binder SET name = ? WHERE id = ?",
                               arguments: [name, binderID])
            }
            binders[index].name = name
        } catch {
            Self.logger.error("renameBinder failed: \(String(describing: error))")
        }
    }

    /// Deletes the binder; its slot_assignment rows go with it via the
    /// ON DELETE CASCADE foreign key.
    func deleteBinder(_ binderID: String) {
        do {
            try database.queue.write { db in
                try db.execute(sql: "DELETE FROM binder WHERE id = ?", arguments: [binderID])
            }
            binders.removeAll { $0.id == binderID }
        } catch {
            Self.logger.error("deleteBinder failed: \(String(describing: error))")
        }
    }

    // MARK: - Spreads

    /// Number of openable spreads: one per "gap" around the sheets, see
    /// SpreadModel — a binder with N sheets has N+1 spreads (0...N).
    func spreadCount(binderID: String) -> Int {
        guard let binder = binders.first(where: { $0.id == binderID }) else { return 0 }
        return binder.pageCount + 1
    }

    /// Builds the render model for spread `spreadIndex` (see SpreadModel for
    /// the sheet/side mapping):
    ///   left  = sheet (spreadIndex-1), BACK side  (absent at spread 0)
    ///   right = sheet  spreadIndex,    FRONT side (absent at spread N)
    func spread(_ spreadIndex: Int, in binderID: String) async throws -> SpreadModel {
        guard let binder = binders.first(where: { $0.id == binderID }),
              spreadIndex >= 0, spreadIndex <= binder.pageCount else {
            return .empty
        }

        var left = [SlotContent?](repeating: nil, count: SpreadModel.slotsPerPage)
        var right = [SlotContent?](repeating: nil, count: SpreadModel.slotsPerPage)

        if spreadIndex > 0 {
            left = try await pageContents(binderID: binderID, pageIndex: spreadIndex - 1, side: .back)
        }
        if spreadIndex < binder.pageCount {
            right = try await pageContents(binderID: binderID, pageIndex: spreadIndex, side: .front)
        }
        return SpreadModel(left: left, right: right)
    }

    private func pageContents(binderID: String, pageIndex: Int, side: PageSide) async throws -> [SlotContent?] {
        let refsBySlot: [(slotIndex: Int, ref: CardRef)] = try await database.queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT slot_index, card_id, variant FROM slot_assignment
                WHERE binder_id = ? AND page_index = ? AND side = ?
                """,
                arguments: [binderID, pageIndex, side.rawValue])
            return rows.compactMap { row in
                guard let variant = CardVariant(rawValue: row["variant"] as String? ?? "") else { return nil }
                return (slotIndex: row["slot_index"] as Int,
                        ref: CardRef(cardID: row["card_id"], variant: variant))
            }
        }

        var slots = [SlotContent?](repeating: nil, count: SpreadModel.slotsPerPage)
        for entry in refsBySlot where (0..<SpreadModel.slotsPerPage).contains(entry.slotIndex) {
            guard let summary = try await cardSummary(for: entry.ref.cardID) else { continue }
            slots[entry.slotIndex] = SlotContent(
                card: summary,
                variant: entry.ref.variant,
                owned: isOwned(entry.ref))
        }
        return slots
    }

    private func cardSummary(for cardID: String) async throws -> CardSummary? {
        if let cached = summaryCache[cardID] { return cached }
        guard let catalog, let detail = try await catalog.card(id: cardID) else { return nil }
        summaryCache[cardID] = detail.summary
        return detail.summary
    }

    // MARK: - Slot assignment

    func assign(_ ref: CardRef, to slot: SlotLocation) {
        guard (0..<SpreadModel.slotsPerPage).contains(slot.slotIndex), slot.pageIndex >= 0 else {
            Self.logger.error("assign: invalid slot index \(slot.slotIndex) / page \(slot.pageIndex)")
            return
        }
        do {
            try database.queue.write { db in
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO slot_assignment
                      (binder_id, page_index, side, slot_index, card_id, variant)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [slot.binderID, slot.pageIndex, slot.side.rawValue,
                                slot.slotIndex, ref.cardID, ref.variant.rawValue])
            }
        } catch {
            Self.logger.error("assign failed: \(String(describing: error))")
        }
    }

    func clear(slot: SlotLocation) {
        do {
            try database.queue.write { db in
                try db.execute(
                    sql: """
                    DELETE FROM slot_assignment
                    WHERE binder_id = ? AND page_index = ? AND side = ? AND slot_index = ?
                    """,
                    arguments: [slot.binderID, slot.pageIndex, slot.side.rawValue, slot.slotIndex])
            }
        } catch {
            Self.logger.error("clear failed: \(String(describing: error))")
        }
    }

    /// How many pockets of a sheet are filled, per side — drives the 3D
    /// page's mass factor (full pages flip heavier and sag more).
    func occupiedSlotCounts(binderID: String, pageIndex: Int) -> (front: Int, back: Int) {
        do {
            let rows = try database.queue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT side, COUNT(*) AS occupied FROM slot_assignment
                    WHERE binder_id = ? AND page_index = ?
                    GROUP BY side
                    """,
                    arguments: [binderID, pageIndex])
            }
            var front = 0, back = 0
            for row in rows {
                switch row["side"] as Int? {
                case PageSide.front.rawValue: front = row["occupied"]
                case PageSide.back.rawValue: back = row["occupied"]
                default: break
                }
            }
            return (front: front, back: back)
        } catch {
            Self.logger.error("occupiedSlotCounts failed: \(String(describing: error))")
            return (front: 0, back: 0)
        }
    }

    // MARK: - Display case

    /// Puts a card into (or clears, with nil) one of the 3 shelf display
    /// slots. Out-of-range positions are ignored.
    func setDisplayCase(_ ref: CardRef?, at position: Int) {
        guard (0..<Self.displayCaseSlotCount).contains(position) else {
            Self.logger.error("setDisplayCase: position \(position) out of bounds")
            return
        }
        do {
            try database.queue.write { db in
                if let ref {
                    try db.execute(
                        sql: "INSERT OR REPLACE INTO display_case (position, card_id, variant) VALUES (?, ?, ?)",
                        arguments: [position, ref.cardID, ref.variant.rawValue])
                } else {
                    try db.execute(sql: "DELETE FROM display_case WHERE position = ?",
                                   arguments: [position])
                }
            }
            displayCase[position] = ref
        } catch {
            Self.logger.error("setDisplayCase failed: \(String(describing: error))")
        }
    }

    // MARK: - Loading

}
