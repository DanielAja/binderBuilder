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
    struct Wish: Codable {
        var cardID, variant: String; var addedAt: Double
        // v3: trade target + show priority (optional to read older backups).
        var targetMode: String?; var targetAmount: Double?; var priority: Int?
    }
    struct Binder: Codable { var id, name, coverColor: String; var pageCount, sortOrder: Int; var createdAt: Double }
    struct Slot: Codable { var binderID: String; var pageIndex, side, slotIndex: Int; var cardID, variant: String }
    struct Display: Codable { var position: Int; var cardID, variant: String }
    struct Group: Codable { var id, name, color: String; var sortOrder: Int; var createdAt: Double }
    struct Member: Codable { var groupID, cardID, variant: String }
    struct Alert: Codable { var cardID, variant, kind: String; var threshold: Double; var baseline: Double?; var createdAt: Double }
    // v3: trade log + for-trade list.
    struct Trade: Codable {
        var id: String; var date: Double; var counterparty, event, location: String?
        var cashDelta: Double; var notes: String?; var createdAt: Double
    }
    struct TradeItem: Codable {
        var id, tradeID, direction, cardID, variant, condition: String
        var quantity: Int; var valueEach: Double?; var note: String?
    }
    struct Listing: Codable {
        var id, cardID, variant, condition: String; var quantity: Int
        var valueMode: String; var valueAmount: Double?; var note: String?; var addedAt: Double
    }

    var version = 3
    var copies: [Copy] = []
    var wishes: [Wish] = []
    var binders: [Binder] = []
    var slots: [Slot] = []
    var displays: [Display] = []
    var groups: [Group] = []
    var members: [Member] = []
    var alerts: [Alert] = []
    // v3: optional, not defaulted — the synthesized Decodable ignores property
    // defaults, so a non-Optional array would make every v2 backup (on-device
    // and in iCloud) fail to restore with `keyNotFound`. Read as `?? []`.
    var trades: [Trade]?
    var tradeItems: [TradeItem]?
    var listings: [Listing]?
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
                .init(cardID: $0["card_id"], variant: $0["variant"], addedAt: $0["added_at"] as Double? ?? 0,
                      targetMode: $0["target_mode"], targetAmount: $0["target_amount"], priority: $0["priority"])
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
            out.groups = try Row.fetchAll(db, sql: "SELECT * FROM card_group").map {
                .init(id: $0["id"], name: $0["name"], color: $0["color"],
                      sortOrder: $0["sort_order"], createdAt: $0["created_at"] as Double? ?? 0)
            }
            out.members = try Row.fetchAll(db, sql: "SELECT * FROM group_member").map {
                .init(groupID: $0["group_id"], cardID: $0["card_id"], variant: $0["variant"])
            }
            out.alerts = try Row.fetchAll(db, sql: "SELECT * FROM price_alert").map {
                .init(cardID: $0["card_id"], variant: $0["variant"], kind: $0["kind"],
                      threshold: $0["threshold"], baseline: $0["baseline"],
                      createdAt: $0["created_at"] as Double? ?? 0)
            }
            out.trades = try Row.fetchAll(db, sql: "SELECT * FROM trade").map {
                .init(id: $0["id"], date: $0["date"] as Double? ?? 0, counterparty: $0["counterparty"],
                      event: $0["event"], location: $0["location"], cashDelta: $0["cash_delta"] as Double? ?? 0,
                      notes: $0["notes"], createdAt: $0["created_at"] as Double? ?? 0)
            }
            out.tradeItems = try Row.fetchAll(db, sql: "SELECT * FROM trade_item").map {
                .init(id: $0["id"], tradeID: $0["trade_id"], direction: $0["direction"], cardID: $0["card_id"],
                      variant: $0["variant"], condition: $0["condition"], quantity: $0["quantity"] as Int? ?? 1,
                      valueEach: $0["value_each"], note: $0["note"])
            }
            out.listings = try Row.fetchAll(db, sql: "SELECT * FROM trade_list").map {
                .init(id: $0["id"], cardID: $0["card_id"], variant: $0["variant"], condition: $0["condition"],
                      quantity: $0["quantity"] as Int? ?? 1, valueMode: $0["value_mode"] as String? ?? "market",
                      valueAmount: $0["value_amount"], note: $0["note"], addedAt: $0["added_at"] as Double? ?? 0)
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
            for table in ["card_copy", "wishlist", "slot_assignment", "display_case",
                          "group_member", "card_group", "price_alert", "binder",
                          "trade_item", "trade", "trade_list"] {
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
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO wishlist (card_id, variant, added_at, target_mode, target_amount, priority)
                    VALUES (?,?,?,?,?,?)
                    """,
                    arguments: [w.cardID, w.variant, w.addedAt,
                                w.targetMode ?? "market", w.targetAmount, w.priority ?? 0])
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
            for g in backup.groups {
                try db.execute(
                    sql: "INSERT INTO card_group (id, name, color, sort_order, created_at) VALUES (?,?,?,?,?)",
                    arguments: [g.id, g.name, g.color, g.sortOrder, g.createdAt])
            }
            for m in backup.members {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO group_member (group_id, card_id, variant) VALUES (?,?,?)",
                    arguments: [m.groupID, m.cardID, m.variant])
            }
            for a in backup.alerts {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO price_alert (card_id, variant, kind, threshold, baseline, created_at) VALUES (?,?,?,?,?,?)",
                    arguments: [a.cardID, a.variant, a.kind, a.threshold, a.baseline, a.createdAt])
            }
            // `?? []` — a v2 payload has no trade keys at all. The tables above
            // are still cleared, so restoring a v2 backup drops trade data by
            // design (it replaces *all* user data with the backup's contents).
            for t in backup.trades ?? [] {
                try db.execute(
                    sql: "INSERT INTO trade (id, date, counterparty, event, location, cash_delta, notes, created_at) VALUES (?,?,?,?,?,?,?,?)",
                    arguments: [t.id, t.date, t.counterparty, t.event, t.location, t.cashDelta, t.notes, t.createdAt])
            }
            for i in backup.tradeItems ?? [] {
                try db.execute(
                    sql: """
                    INSERT INTO trade_item (id, trade_id, direction, card_id, variant, condition, quantity, value_each, note)
                    VALUES (?,?,?,?,?,?,?,?,?)
                    """,
                    arguments: [i.id, i.tradeID, i.direction, i.cardID, i.variant, i.condition, i.quantity, i.valueEach, i.note])
            }
            for l in backup.listings ?? [] {
                try db.execute(
                    sql: """
                    INSERT INTO trade_list (id, card_id, variant, condition, quantity, value_mode, value_amount, note, added_at)
                    VALUES (?,?,?,?,?,?,?,?,?)
                    """,
                    arguments: [l.id, l.cardID, l.variant, l.condition, l.quantity, l.valueMode, l.valueAmount, l.note, l.addedAt])
            }
        }
    }
}
