//
//  CollectionStore.swift
//  binderBuilder
//
//  Ownership state, backed by per-copy rows (card_copy). Each physical copy
//  carries its own condition / grade / acquisition. The legacy printing-level
//  API (isOwned / quantity / setOwned / ownedRefs / ownedCount) is preserved
//  as a facade so the 3D binder, BinderStore, DemoSeed, and content snapshots
//  are untouched; richer per-copy CRUD is layered on top.
//
//  In-memory mirror for synchronous UI; writes go through UserDatabase.
//  `changeToken` bumps on every mutation so dependent stores (stats, value)
//  can recompute.
//

import Foundation
import GRDB
import Observation
import os

@MainActor @Observable final class CollectionStore {
    private let database: UserDatabase

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.aja.binderBuilder", category: "CollectionStore")

    /// In-memory mirror of card_copy, grouped by printing.
    private(set) var copiesByRef: [CardRef: [CardCopy]] = [:]
    /// Increments on every mutation (cheap signal for observers).
    private(set) var changeToken: Int = 0

    init(database: UserDatabase) {
        self.database = database
        do {
            let rows = try database.queue.read { db in
                try Row.fetchAll(db, sql: Self.selectCopies)
            }
            for row in rows {
                guard let copy = Self.copy(from: row) else { continue }
                copiesByRef[copy.ref, default: []].append(copy)
            }
        } catch {
            Self.logger.error("failed to load copies: \(String(describing: error))")
        }
    }

    // MARK: - Legacy printing-level API (kept stable)

    /// Distinct owned (card, variant) printings.
    var ownedCount: Int { copiesByRef.count }

    /// Total number of physical copies across all printings.
    var totalCopies: Int { copiesByRef.values.reduce(0) { $0 + $1.count } }

    func isOwned(_ ref: CardRef) -> Bool { !(copiesByRef[ref]?.isEmpty ?? true) }

    func quantity(of ref: CardRef) -> Int { copiesByRef[ref]?.count ?? 0 }

    /// All owned printings, for the price-refresh pass.
    func ownedRefs() -> [CardRef] { Array(copiesByRef.keys) }

    /// All distinct owned card IDs (for catalog aggregates / set completion).
    func ownedCardIDs() -> [String] { Array(Set(copiesByRef.keys.map(\.cardID))) }

    /// Adjusts the number of copies of a printing to `quantity` by adding raw
    /// Near-Mint copies or removing copies (raw first, preserving graded ones).
    /// quantity <= 0 removes every copy of the printing.
    func setOwned(_ ref: CardRef, quantity: Int = 1) {
        let current = self.quantity(of: ref)
        if quantity <= 0 {
            removeAllCopies(of: ref)
        } else if quantity > current {
            for _ in 0..<(quantity - current) {
                _ = addCopy(ref, condition: .nm)
            }
        } else if quantity < current {
            removeCopies(of: ref, count: current - quantity)
        }
    }

    // MARK: - Per-copy API

    func copies(of ref: CardRef) -> [CardCopy] {
        (copiesByRef[ref] ?? []).sorted { $0.acquiredAt < $1.acquiredAt }
    }

    /// All owned copies (e.g. for the Collection grid / value), newest first.
    func allCopies() -> [CardCopy] {
        copiesByRef.values.flatMap { $0 }.sorted { $0.acquiredAt > $1.acquiredAt }
    }

    @discardableResult
    func addCopy(
        _ ref: CardRef,
        condition: CardCondition = .nm,
        grade: CardGrade? = nil,
        acquiredPrice: Double? = nil,
        notes: String? = nil
    ) -> CardCopy? {
        var copy = CardCopy(ref: ref, condition: condition, grade: grade,
                            acquiredPrice: acquiredPrice, notes: notes)
        do {
            try database.queue.write { db in try Self.insert(copy, into: db) }
            copiesByRef[ref, default: []].append(copy)
            bump()
            return copy
        } catch {
            Self.logger.error("addCopy failed: \(String(describing: error))")
            return nil
        }
    }

    func updateCopy(_ copy: CardCopy) {
        do {
            try database.queue.write { db in try Self.update(copy, in: db) }
            if let i = copiesByRef[copy.ref]?.firstIndex(where: { $0.id == copy.id }) {
                copiesByRef[copy.ref]?[i] = copy
            }
            bump()
        } catch {
            Self.logger.error("updateCopy failed: \(String(describing: error))")
        }
    }

    func removeCopy(_ id: String) {
        do {
            try database.queue.write { db in
                try db.execute(sql: "DELETE FROM card_copy WHERE id = ?", arguments: [id])
            }
            for (ref, copies) in copiesByRef where copies.contains(where: { $0.id == id }) {
                copiesByRef[ref]?.removeAll { $0.id == id }
                if copiesByRef[ref]?.isEmpty == true { copiesByRef[ref] = nil }
                break
            }
            bump()
        } catch {
            Self.logger.error("removeCopy failed: \(String(describing: error))")
        }
    }

    // MARK: - Helpers

    private func removeAllCopies(of ref: CardRef) {
        do {
            try database.queue.write { db in
                try db.execute(
                    sql: "DELETE FROM card_copy WHERE card_id = ? AND variant = ?",
                    arguments: [ref.cardID, ref.variant.rawValue])
            }
            copiesByRef[ref] = nil
            bump()
        } catch {
            Self.logger.error("removeAllCopies failed: \(String(describing: error))")
        }
    }

    /// Removes `count` copies of a printing, raw (ungraded) and worst-condition
    /// first so graded slabs survive a quantity decrement.
    private func removeCopies(of ref: CardRef, count: Int) {
        guard var copies = copiesByRef[ref], count > 0 else { return }
        let order: [CardCondition] = [.dmg, .hp, .mp, .lp, .nm]
        let toRemove = copies
            .sorted { a, b in
                if a.isGraded != b.isGraded { return !a.isGraded } // raw first
                return (order.firstIndex(of: a.condition) ?? 0) < (order.firstIndex(of: b.condition) ?? 0)
            }
            .prefix(count)
        let ids = Set(toRemove.map(\.id))
        do {
            try database.queue.write { db in
                for id in ids {
                    try db.execute(sql: "DELETE FROM card_copy WHERE id = ?", arguments: [id])
                }
            }
            copies.removeAll { ids.contains($0.id) }
            copiesByRef[ref] = copies.isEmpty ? nil : copies
            bump()
        } catch {
            Self.logger.error("removeCopies failed: \(String(describing: error))")
        }
    }

    private func bump() { changeToken &+= 1 }

    // MARK: - Row mapping

    private static let selectCopies = """
        SELECT id, card_id, variant, condition, grade_company, grade_value,
               acquired_price, acquired_at, notes
        FROM card_copy
        """

    private static func copy(from row: Row) -> CardCopy? {
        guard let variant = CardVariant(rawValue: row["variant"] as String? ?? ""),
              let condition = CardCondition(rawValue: row["condition"] as String? ?? "NM")
        else { return nil }
        var grade: CardGrade?
        if let companyRaw = row["grade_company"] as String?,
           let company = GradeCompany(rawValue: companyRaw),
           let value = row["grade_value"] as Double? {
            grade = CardGrade(company: company, value: value)
        }
        return CardCopy(
            id: row["id"],
            ref: CardRef(cardID: row["card_id"], variant: variant),
            condition: condition,
            grade: grade,
            acquiredPrice: row["acquired_price"],
            acquiredAt: Date(timeIntervalSince1970: row["acquired_at"] as Double? ?? 0),
            notes: row["notes"])
    }

    private static func insert(_ copy: CardCopy, into db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO card_copy
              (id, card_id, variant, condition, grade_company, grade_value, acquired_price, acquired_at, notes)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [copy.id, copy.ref.cardID, copy.ref.variant.rawValue, copy.condition.rawValue,
                        copy.grade?.company.rawValue, copy.grade?.value,
                        copy.acquiredPrice, copy.acquiredAt.timeIntervalSince1970, copy.notes])
    }

    private static func update(_ copy: CardCopy, in db: Database) throws {
        try db.execute(
            sql: """
            UPDATE card_copy SET condition = ?, grade_company = ?, grade_value = ?,
                acquired_price = ?, notes = ?
            WHERE id = ?
            """,
            arguments: [copy.condition.rawValue, copy.grade?.company.rawValue, copy.grade?.value,
                        copy.acquiredPrice, copy.notes, copy.id])
    }
}
