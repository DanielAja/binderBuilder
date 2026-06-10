//
//  BackupService.swift
//  binderBuilder
//
//  JSON export/import of the user's collection (copies, wishlist, binders,
//  slot assignments, display case) so data is never trapped on one device and
//  can survive a reinstall — addressing the "data loss / no backup" pain point.
//  Restore replaces all user data; the app should be relaunched afterward so
//  the in-memory stores reload.
//

import Foundation
import GRDB

struct BackupData: Codable {
    struct Copy: Codable {
        var id, cardID, variant, condition: String
        var gradeCompany: String?, gradeValue: Double?, acquiredPrice: Double?
        var acquiredAt: Double, notes: String?
    }
    struct Wish: Codable { var cardID, variant: String; var addedAt: Double }
    struct Binder: Codable { var id, name, coverColor: String; var pageCount, sortOrder: Int; var createdAt: Double }
    struct Slot: Codable { var binderID: String; var pageIndex, side, slotIndex: Int; var cardID, variant: String }
    struct Display: Codable { var position: Int; var cardID, variant: String }

    var version = 1
    var copies: [Copy] = []
    var wishes: [Wish] = []
    var binders: [Binder] = []
    var slots: [Slot] = []
    var displays: [Display] = []
}

enum BackupService {
    static func export(_ database: UserDatabase) throws -> Data {
        let data = try database.queue.read { db -> BackupData in
            var out = BackupData()
            out.copies = try Row.fetchAll(db, sql: "SELECT * FROM card_copy").map {
                .init(id: $0["id"], cardID: $0["card_id"], variant: $0["variant"], condition: $0["condition"],
                      gradeCompany: $0["grade_company"], gradeValue: $0["grade_value"],
                      acquiredPrice: $0["acquired_price"], acquiredAt: $0["acquired_at"] as Double? ?? 0,
                      notes: $0["notes"])
            }
            out.wishes = try Row.fetchAll(db, sql: "SELECT * FROM wishlist").map {
                .init(cardID: $0["card_id"], variant: $0["variant"], addedAt: $0["added_at"] as Double? ?? 0)
            }
            out.binders = try Row.fetchAll(db, sql: "SELECT * FROM binder").map {
                .init(id: $0["id"], name: $0["name"], coverColor: $0["cover_color"],
                      pageCount: $0["page_count"], sortOrder: $0["sort_order"],
                      createdAt: $0["created_at"] as Double? ?? 0)
            }
            out.slots = try Row.fetchAll(db, sql: "SELECT * FROM slot_assignment").map {
                .init(binderID: $0["binder_id"], pageIndex: $0["page_index"], side: $0["side"],
                      slotIndex: $0["slot_index"], cardID: $0["card_id"], variant: $0["variant"])
            }
            out.displays = try Row.fetchAll(db, sql: "SELECT * FROM display_case").map {
                .init(position: $0["position"], cardID: $0["card_id"], variant: $0["variant"])
            }
            return out
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(data)
    }

    /// Replaces all user data with the backup's contents.
    static func restore(_ jsonData: Data, into database: UserDatabase) throws {
        let backup = try JSONDecoder().decode(BackupData.self, from: jsonData)
        try database.queue.write { db in
            for table in ["card_copy", "wishlist", "slot_assignment", "display_case", "binder"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
            for b in backup.binders {
                try db.execute(
                    sql: "INSERT INTO binder (id, name, cover_color, page_count, sort_order, created_at) VALUES (?,?,?,?,?,?)",
                    arguments: [b.id, b.name, b.coverColor, b.pageCount, b.sortOrder, b.createdAt])
            }
            for c in backup.copies {
                try db.execute(
                    sql: """
                    INSERT INTO card_copy (id, card_id, variant, condition, grade_company, grade_value, acquired_price, acquired_at, notes)
                    VALUES (?,?,?,?,?,?,?,?,?)
                    """,
                    arguments: [c.id, c.cardID, c.variant, c.condition, c.gradeCompany, c.gradeValue,
                                c.acquiredPrice, c.acquiredAt, c.notes])
            }
            for w in backup.wishes {
                try db.execute(sql: "INSERT OR IGNORE INTO wishlist (card_id, variant, added_at) VALUES (?,?,?)",
                               arguments: [w.cardID, w.variant, w.addedAt])
            }
            for s in backup.slots {
                try db.execute(
                    sql: "INSERT INTO slot_assignment (binder_id, page_index, side, slot_index, card_id, variant) VALUES (?,?,?,?,?,?)",
                    arguments: [s.binderID, s.pageIndex, s.side, s.slotIndex, s.cardID, s.variant])
            }
            for d in backup.displays {
                try db.execute(sql: "INSERT INTO display_case (position, card_id, variant) VALUES (?,?,?)",
                               arguments: [d.position, d.cardID, d.variant])
            }
        }
    }
}
