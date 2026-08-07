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
    /// The shelf display-case slots (count is user-configurable, see
    /// `setDisplayCaseCount`; sized from shelf_config on load).
    private(set) var displayCase: [CardRef?] = Array(repeating: nil, count: displayCaseMinCount)
    /// Increments when a binder's slot layout is edited through a path that
    /// expects observers to refresh: a sort's whole-binder rewrite, or a
    /// single-pocket `setSlot`/`clearSlot` from the 3D pocket editor. The
    /// quiet bulk writers (`assign`/`clear`) do not bump it — seeding and
    /// scan commits re-snapshot on their own.
    private(set) var changeToken: Int = 0

    /// CardSummary lookups are cached for the life of the store (the catalog
    /// is immutable).
    @ObservationIgnored private var summaryCache: [String: CardSummary] = [:]

    nonisolated static let displayCaseMinCount = 3
    nonisolated static let displayCaseMaxCount = 5

    var displayCaseCount: Int { displayCase.count }

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
            let loaded = try await database.queue.read { db -> ([Binder], [Display], Int) in
                let binders = try Row.fetchAll(db, sql: """
                    SELECT id, name, cover_color, page_count, sort_order
                    FROM binder ORDER BY sort_order
                    """).map { row in
                        Binder(id: row["id"], name: row["name"], coverColor: row["cover_color"],
                               pageCount: row["page_count"], sortOrder: row["sort_order"])
                    }
                let slotCount = try Int.fetchOne(
                    db, sql: "SELECT display_slot_count FROM shelf_config WHERE id = 0")
                    ?? Self.displayCaseMinCount
                let clamped = min(max(slotCount, Self.displayCaseMinCount), Self.displayCaseMaxCount)
                let display = try Row.fetchAll(db, sql: "SELECT position, card_id, variant FROM display_case").compactMap { row -> Display? in
                    guard let position = row["position"] as Int?,
                          (0..<clamped).contains(position),
                          let variant = CardVariant(rawValue: row["variant"] as String? ?? "") else { return nil }
                    return Display(position: position, ref: CardRef(cardID: row["card_id"], variant: variant))
                }
                return (binders, display, clamped)
            }
            binders = loaded.0
            var slots: [CardRef?] = Array(repeating: nil, count: loaded.2)
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
    /// ON DELETE CASCADE foreign key. Bumps `changeToken` (slots vanished).
    func deleteBinder(_ binderID: String) {
        do {
            try database.queue.write { db in
                try db.execute(sql: "DELETE FROM binder WHERE id = ?", arguments: [binderID])
            }
            binders.removeAll { $0.id == binderID }
            changeToken += 1
        } catch {
            Self.logger.error("deleteBinder failed: \(String(describing: error))")
        }
    }

    /// Rewrites every binder's sort_order to match `orderedIDs` (ids not in
    /// the list keep their relative order after the listed ones).
    func reorderBinders(_ orderedIDs: [String]) {
        let rank = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($1, $0) })
        let reordered = binders.sorted {
            (rank[$0.id] ?? Int.max, $0.sortOrder) < (rank[$1.id] ?? Int.max, $1.sortOrder)
        }
        do {
            try database.queue.write { db in
                for (order, binder) in reordered.enumerated() {
                    try db.execute(sql: "UPDATE binder SET sort_order = ? WHERE id = ?",
                                   arguments: [order, binder.id])
                }
            }
            binders = reordered.enumerated().map { order, binder in
                var updated = binder
                updated.sortOrder = order
                return updated
            }
        } catch {
            Self.logger.error("reorderBinders failed: \(String(describing: error))")
        }
    }

    func setCoverColor(_ binderID: String, to hex: String) {
        guard let index = binders.firstIndex(where: { $0.id == binderID }) else { return }
        do {
            try database.queue.write { db in
                try db.execute(sql: "UPDATE binder SET cover_color = ? WHERE id = ?",
                               arguments: [hex, binderID])
            }
            binders[index].coverColor = hex
        } catch {
            Self.logger.error("setCoverColor failed: \(String(describing: error))")
        }
    }

    // MARK: - Page management

    /// Appends `count` blank sheets to the back of the binder.
    @discardableResult
    func addPages(_ count: Int = 1, to binderID: String) -> Bool {
        guard count > 0, let index = binders.firstIndex(where: { $0.id == binderID }) else { return false }
        do {
            try database.queue.write { db in
                try db.execute(sql: "UPDATE binder SET page_count = page_count + ? WHERE id = ?",
                               arguments: [count, binderID])
            }
            binders[index].pageCount += count
            changeToken += 1
            return true
        } catch {
            Self.logger.error("addPages failed: \(String(describing: error))")
            return false
        }
    }

    /// Inserts a blank sheet at `pageIndex` (0...pageCount; pageCount appends),
    /// shifting the sheets at and after it — including any orphan rows beyond
    /// the page range — up by one. One transaction.
    ///
    /// The shift uses a negate-and-flip two-step so the composite primary key
    /// never transiently collides: rows move to distinct negative indices
    /// first, then flip to their final positive positions.
    @discardableResult
    func insertPage(at pageIndex: Int, in binderID: String) -> Bool {
        guard let index = binders.firstIndex(where: { $0.id == binderID }),
              (0...binders[index].pageCount).contains(pageIndex) else { return false }
        do {
            try database.queue.write { db in
                try db.execute(
                    sql: "UPDATE slot_assignment SET page_index = -(page_index + 1) WHERE binder_id = ? AND page_index >= ?",
                    arguments: [binderID, pageIndex])
                try db.execute(
                    sql: "UPDATE slot_assignment SET page_index = -page_index WHERE binder_id = ? AND page_index < 0",
                    arguments: [binderID])
                try db.execute(sql: "UPDATE binder SET page_count = page_count + 1 WHERE id = ?",
                               arguments: [binderID])
            }
            binders[index].pageCount += 1
            changeToken += 1
            return true
        } catch {
            Self.logger.error("insertPage failed: \(String(describing: error))")
            return false
        }
    }

    /// Removes sheet `pageIndex`: its assignments are DELETED (the cards stay
    /// in the collection — surface the count via `assignmentCount` and confirm
    /// before calling), and later sheets — including orphan rows — shift down
    /// by one. One transaction; same collision-safe two-step as `insertPage`.
    @discardableResult
    func removePage(at pageIndex: Int, from binderID: String) -> Bool {
        guard let index = binders.firstIndex(where: { $0.id == binderID }),
              (0..<binders[index].pageCount).contains(pageIndex) else { return false }
        do {
            try database.queue.write { db in
                try db.execute(
                    sql: "DELETE FROM slot_assignment WHERE binder_id = ? AND page_index = ?",
                    arguments: [binderID, pageIndex])
                try db.execute(
                    sql: "UPDATE slot_assignment SET page_index = -(page_index - 1) WHERE binder_id = ? AND page_index > ?",
                    arguments: [binderID, pageIndex])
                try db.execute(
                    sql: "UPDATE slot_assignment SET page_index = -page_index WHERE binder_id = ? AND page_index < 0",
                    arguments: [binderID])
                try db.execute(sql: "UPDATE binder SET page_count = page_count - 1 WHERE id = ?",
                               arguments: [binderID])
            }
            binders[index].pageCount -= 1
            changeToken += 1
            return true
        } catch {
            Self.logger.error("removePage failed: \(String(describing: error))")
            return false
        }
    }

    /// How many cards sit on sheet `pageIndex` (both sides) — for the
    /// remove-page confirmation dialog.
    func assignmentCount(binderID: String, pageIndex: Int) -> Int {
        let counts = occupiedSlotCounts(binderID: binderID, pageIndex: pageIndex)
        return counts.front + counts.back
    }

    /// Total cards placed in the binder — for list rows and detail stats.
    func occupiedCount(binderID: String) -> Int {
        (try? database.queue.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM slot_assignment WHERE binder_id = ?",
                arguments: [binderID]) ?? 0
        }) ?? 0
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

    /// Quiet bulk placement (seeding, scan commits, "add to binder"): writes the
    /// pocket without bumping `changeToken`, because those paths re-snapshot the
    /// binder themselves. Returns false when the write failed or the slot
    /// address was out of range.
    @discardableResult
    func assign(_ ref: CardRef, to slot: SlotLocation) -> Bool {
        guard (0..<SpreadModel.slotsPerPage).contains(slot.slotIndex), slot.pageIndex >= 0 else {
            Self.logger.error("assign: invalid slot index \(slot.slotIndex) / page \(slot.pageIndex)")
            return false
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
            return true
        } catch {
            Self.logger.error("assign failed: \(String(describing: error))")
            return false
        }
    }

    @discardableResult
    func clear(slot: SlotLocation) -> Bool {
        do {
            try database.queue.write { db in
                try db.execute(
                    sql: """
                    DELETE FROM slot_assignment
                    WHERE binder_id = ? AND page_index = ? AND side = ? AND slot_index = ?
                    """,
                    arguments: [slot.binderID, slot.pageIndex, slot.side.rawValue, slot.slotIndex])
            }
            return true
        } catch {
            Self.logger.error("clear failed: \(String(describing: error))")
            return false
        }
    }

    // MARK: - Single-pocket edits (from the 3D binder's pocket editor)

    /// Puts `ref` in one pocket, replacing whatever was there, in a single
    /// transaction, and bumps `changeToken` so observers holding a layout (the
    /// 3D snapshot) know it is stale. Duplicates are allowed on purpose —
    /// collectors legitimately own several copies of the same printing.
    /// Returns false when the write failed (the caller should surface that).
    @discardableResult
    func setSlot(_ ref: CardRef, at slot: SlotLocation) -> Bool {
        guard assign(ref, to: slot) else { return false }
        changeToken += 1
        return true
    }

    /// Empties one pocket in a single transaction and bumps `changeToken`.
    /// Clearing an already-empty pocket succeeds (it is idempotent).
    @discardableResult
    func clearSlot(_ slot: SlotLocation) -> Bool {
        guard clear(slot: slot) else { return false }
        changeToken += 1
        return true
    }

    // MARK: - Moving cards between pockets

    /// Pockets per sheet (front 0-8, then back 0-8) — the unit of the linear
    /// pocket ordinal used by moves.
    private nonisolated static let slotsPerSheet = 2 * SpreadModel.slotsPerPage

    /// Linear reading-order position of a pocket: front-to-back, front side
    /// before back, row-major — the same order `firstEmptySlot` fills and
    /// `BinderSort.slotSequence` lays down.
    nonisolated static func ordinal(of slot: SlotLocation) -> Int {
        slot.pageIndex * slotsPerSheet + slot.side.rawValue * SpreadModel.slotsPerPage + slot.slotIndex
    }

    nonisolated static func slotLocation(atOrdinal ordinal: Int, binderID: String) -> SlotLocation {
        SlotLocation(
            binderID: binderID,
            pageIndex: ordinal / slotsPerSheet,
            side: (ordinal % slotsPerSheet) < SpreadModel.slotsPerPage ? .front : .back,
            slotIndex: ordinal % SpreadModel.slotsPerPage)
    }

    /// Moves the card in `from` to `to` (same binder), resolving an occupied
    /// target per `mode` — see `SlotMoveMode`. The whole rewrite is one
    /// transaction; `changeToken` bumps on success.
    ///
    /// Returns nil — with the database untouched — when `from` is empty, the
    /// addresses are invalid, or an insert-shift finds no gap through the last
    /// pocket (the caller should offer "add a page").
    func moveCard(from: SlotLocation, to: SlotLocation, mode: SlotMoveMode) -> MoveResult? {
        guard from.binderID == to.binderID, from != to,
              let binder = binders.first(where: { $0.id == from.binderID }) else { return nil }
        let maxOrdinal = binder.pageCount * Self.slotsPerSheet - 1
        let source = Self.ordinal(of: from)
        let target = Self.ordinal(of: to)
        guard (0...maxOrdinal).contains(source), (0...maxOrdinal).contains(target),
              (0..<SpreadModel.slotsPerPage).contains(from.slotIndex),
              (0..<SpreadModel.slotsPerPage).contains(to.slotIndex) else { return nil }

        do {
            var byOrdinal: [Int: CardRef] = try database.queue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT page_index, side, slot_index, card_id, variant FROM slot_assignment
                    WHERE binder_id = ? AND page_index < ? AND slot_index < ?
                    """,
                    arguments: [from.binderID, binder.pageCount, SpreadModel.slotsPerPage])
                var map: [Int: CardRef] = [:]
                for row in rows {
                    guard let side = PageSide(rawValue: row["side"] as Int? ?? -1),
                          let variant = CardVariant(rawValue: row["variant"] as String? ?? "") else { continue }
                    let location = SlotLocation(
                        binderID: from.binderID, pageIndex: row["page_index"],
                        side: side, slotIndex: row["slot_index"])
                    map[Self.ordinal(of: location)] = CardRef(cardID: row["card_id"], variant: variant)
                }
                return map
            }
            guard let moved = byOrdinal.removeValue(forKey: source) else { return nil }

            var affected: Set<Int> = [source, target]
            var shifted: [SlotLocation] = []
            switch mode {
            case .swap:
                let displaced = byOrdinal[target]
                byOrdinal[target] = moved
                byOrdinal[source] = displaced
            case .insertShift:
                var carry = moved
                var ordinal = target
                while let occupant = byOrdinal[ordinal] {
                    byOrdinal[ordinal] = carry
                    carry = occupant
                    ordinal += 1
                    guard ordinal <= maxOrdinal else { return nil }   // no gap left; DB untouched
                    affected.insert(ordinal)
                    shifted.append(Self.slotLocation(atOrdinal: ordinal, binderID: from.binderID))
                }
                byOrdinal[ordinal] = carry
            }

            let binderID = from.binderID
            let writes: [(SlotLocation, CardRef?)] = affected.sorted().map {
                (Self.slotLocation(atOrdinal: $0, binderID: binderID), byOrdinal[$0])
            }
            try database.queue.write { db in
                for (location, ref) in writes {
                    try db.execute(
                        sql: """
                        DELETE FROM slot_assignment
                        WHERE binder_id = ? AND page_index = ? AND side = ? AND slot_index = ?
                        """,
                        arguments: [binderID, location.pageIndex, location.side.rawValue, location.slotIndex])
                    if let ref {
                        try db.execute(
                            sql: """
                            INSERT INTO slot_assignment
                              (binder_id, page_index, side, slot_index, card_id, variant)
                            VALUES (?, ?, ?, ?, ?, ?)
                            """,
                            arguments: [binderID, location.pageIndex, location.side.rawValue,
                                        location.slotIndex, ref.cardID, ref.variant.rawValue])
                    }
                }
            }
            changeToken += 1
            return MoveResult(shifted: shifted)
        } catch {
            Self.logger.error("moveCard failed: \(String(describing: error))")
            return nil
        }
    }

    // MARK: - Undo snapshots + batched writes

    /// Every assignment in the binder, in pocket order — the 2D editor's undo
    /// unit. Synchronous read (a binder tops out at a few hundred rows).
    func assignments(binderID: String) -> [SlotAssignmentRow] {
        do {
            return try database.queue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT page_index, side, slot_index, card_id, variant FROM slot_assignment
                    WHERE binder_id = ? ORDER BY page_index, side, slot_index
                    """,
                    arguments: [binderID])
                return rows.compactMap { row -> SlotAssignmentRow? in
                    guard let side = PageSide(rawValue: row["side"] as Int? ?? -1),
                          let variant = CardVariant(rawValue: row["variant"] as String? ?? "") else { return nil }
                    return SlotAssignmentRow(
                        location: SlotLocation(binderID: binderID, pageIndex: row["page_index"],
                                               side: side, slotIndex: row["slot_index"]),
                        ref: CardRef(cardID: row["card_id"], variant: variant))
                }
            }
        } catch {
            Self.logger.error("assignments failed: \(String(describing: error))")
            return []
        }
    }

    /// Replaces the binder's whole slot layout with `rows` (an `assignments`
    /// snapshot) in one transaction. Rows for other binders are ignored.
    @discardableResult
    func restoreAssignments(_ rows: [SlotAssignmentRow], binderID: String) -> Bool {
        do {
            try database.queue.write { db in
                try db.execute(sql: "DELETE FROM slot_assignment WHERE binder_id = ?",
                               arguments: [binderID])
                for row in rows where row.location.binderID == binderID {
                    try db.execute(
                        sql: """
                        INSERT INTO slot_assignment
                          (binder_id, page_index, side, slot_index, card_id, variant)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [binderID, row.location.pageIndex, row.location.side.rawValue,
                                    row.location.slotIndex, row.ref.cardID, row.ref.variant.rawValue])
                }
            }
            changeToken += 1
            return true
        } catch {
            Self.logger.error("restoreAssignments failed: \(String(describing: error))")
            return false
        }
    }

    /// Runs a series of quiet writes (`assign`/`clear`/`setOwned`-style loops)
    /// and bumps `changeToken` exactly once at the end, so observers refresh
    /// once instead of per row. Scan commits and bulk adds use this.
    func commitBatch(_ body: (BinderStore) -> Void) {
        body(self)
        changeToken += 1
    }

    // MARK: - Sorting

    /// Reorders every card in `binderID` by `key` and lays them back down from
    /// the first pocket forward. The sort COMPACTS (see BinderSort): gaps close
    /// up and the empty pockets become one tail at the back. The binder's page
    /// count is untouched, and rows outside its current page range — a leftover
    /// from a binder that shrank — are left exactly where they are.
    ///
    /// The whole rewrite is one transaction; `changeToken` bumps on success.
    /// Returns false when there is nothing to sort, or when the app is running
    /// without a catalog (names, sets, rarities and prices all live there).
    @discardableResult
    func sort(binderID: String, by key: BinderSortKey) async -> Bool {
        guard let binder = binders.first(where: { $0.id == binderID }),
              binder.pageCount > 0,
              let catalog
        else { return false }

        do {
            let refs = try await database.queue.read { db -> [CardRef] in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT card_id, variant FROM slot_assignment
                    WHERE binder_id = ? AND page_index < ? AND slot_index < ?
                    ORDER BY page_index, side, slot_index
                    """,
                    arguments: [binderID, binder.pageCount, SpreadModel.slotsPerPage])
                return rows.compactMap { row in
                    guard let variant = CardVariant(rawValue: row["variant"] as String? ?? "") else { return nil }
                    return CardRef(cardID: row["card_id"], variant: variant)
                }
            }
            guard !refs.isEmpty else { return false }

            let ordered = BinderSort.sorted(try await sortEntries(for: refs, catalog: catalog), by: key)
            let slots = BinderSort.slotSequence(binderID: binderID, pageCount: binder.pageCount)
            try await database.queue.write { db in
                try db.execute(
                    sql: "DELETE FROM slot_assignment WHERE binder_id = ? AND page_index < ? AND slot_index < ?",
                    arguments: [binderID, binder.pageCount, SpreadModel.slotsPerPage])
                for (entry, slot) in zip(ordered, slots) {
                    try db.execute(
                        sql: """
                        INSERT INTO slot_assignment
                          (binder_id, page_index, side, slot_index, card_id, variant)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [slot.binderID, slot.pageIndex, slot.side.rawValue,
                                    slot.slotIndex, entry.ref.cardID, entry.ref.variant.rawValue])
                }
            }
            changeToken += 1
            return true
        } catch {
            Self.logger.error("sort failed: \(String(describing: error))")
            return false
        }
    }

    /// Decorates the binder's pocket refs with the catalog metadata the
    /// ordering needs, in three batched queries (summaries, sets, prices).
    private func sortEntries(for refs: [CardRef], catalog: any CatalogReading) async throws -> [BinderSortEntry] {
        let summaries = try await catalog.summaries(forCardIDs: Array(Set(refs.map(\.cardID))))
        var summaryByID: [String: CardSummary] = [:]
        for summary in summaries {
            summaryByID[summary.id] = summary
            summaryCache[summary.id] = summary
        }
        // allSets() already comes back in release order.
        var releaseOrder: [String: Int] = [:]
        for (index, set) in (try await catalog.allSets()).enumerated() { releaseOrder[set.id] = index }
        let market = try await catalog.bundledMarket(for: refs)

        return refs.map { ref in
            let summary = summaryByID[ref.cardID]
            return BinderSortEntry(
                ref: ref,
                name: summary?.name ?? ref.cardID,
                setOrder: summary.flatMap { releaseOrder[$0.setID] } ?? Int.max,
                localNumber: summary?.localNumber ?? "",
                rarity: summary?.rarity,
                market: market[ref])
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

    /// Puts a card into (or clears, with nil) one of the shelf display
    /// slots. Out-of-range positions are ignored.
    func setDisplayCase(_ ref: CardRef?, at position: Int) {
        guard (0..<displayCase.count).contains(position) else {
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

    /// First empty display slot, for "Add to Display Case" from a card's
    /// context menu. nil when every case is occupied.
    func firstEmptyDisplaySlot() -> Int? {
        displayCase.firstIndex(where: { $0 == nil })
    }

    /// Grows or shrinks the shelf's display-case row (clamped to
    /// `displayCaseMinCount...displayCaseMaxCount`). Shrinking clears the
    /// trailing slots' cards in the same transaction.
    @discardableResult
    func setDisplayCaseCount(_ count: Int) -> Bool {
        let clamped = min(max(count, Self.displayCaseMinCount), Self.displayCaseMaxCount)
        guard clamped != displayCase.count else { return false }
        do {
            try database.queue.write { db in
                try db.execute(sql: "UPDATE shelf_config SET display_slot_count = ? WHERE id = 0",
                               arguments: [clamped])
                try db.execute(sql: "DELETE FROM display_case WHERE position >= ?",
                               arguments: [clamped])
            }
            if clamped > displayCase.count {
                displayCase.append(contentsOf: Array(repeating: nil, count: clamped - displayCase.count))
            } else {
                displayCase = Array(displayCase.prefix(clamped))
            }
            return true
        } catch {
            Self.logger.error("setDisplayCaseCount failed: \(String(describing: error))")
            return false
        }
    }

    /// The display-case slots resolved to renderable content (nil = empty
    /// slot, or a ref whose card is missing from the catalog).
    func displayCaseContents() async -> [SlotContent?] {
        var contents: [SlotContent?] = []
        for ref in displayCase {
            guard let ref, let summary = try? await cardSummary(for: ref.cardID) else {
                contents.append(nil)
                continue
            }
            contents.append(SlotContent(card: summary, variant: ref.variant, owned: isOwned(ref)))
        }
        return contents
    }

    // MARK: - Loading

}
