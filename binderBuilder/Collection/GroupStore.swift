//
//  GroupStore.swift
//  binderBuilder
//
//  Custom collection groups ("For Trade", "Vintage", "Charizards", …) and the
//  cards assigned to them. Mirrors card_group + group_member in memory for
//  synchronous UI; `changeToken` bumps on mutation.
//

import Foundation
import GRDB
import Observation
import os

nonisolated struct CardGroup: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var color: String
    var sortOrder: Int
}

@MainActor @Observable final class GroupStore {
    private let database: UserDatabase

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.aja.binderBuilder", category: "GroupStore")

    /// A palette new groups cycle through.
    static let palette = ["#E4572E", "#1B6CA8", "#2E933C", "#A12FA0", "#E8A33D", "#3DA0A0"]

    private(set) var groups: [CardGroup] = []
    private(set) var membersByGroup: [String: Set<CardRef>] = [:]
    private(set) var changeToken = 0

    init(database: UserDatabase) {
        self.database = database
        do {
            try database.queue.read { db in
                for row in try Row.fetchAll(db, sql: "SELECT id, name, color, sort_order FROM card_group ORDER BY sort_order") {
                    groups.append(CardGroup(id: row["id"], name: row["name"], color: row["color"], sortOrder: row["sort_order"]))
                }
                for row in try Row.fetchAll(db, sql: "SELECT group_id, card_id, variant FROM group_member") {
                    guard let variant = CardVariant(rawValue: row["variant"] as String? ?? "") else { continue }
                    membersByGroup[row["group_id"], default: []].insert(CardRef(cardID: row["card_id"], variant: variant))
                }
            }
        } catch {
            Self.logger.error("failed to load groups: \(String(describing: error))")
        }
    }

    // MARK: Group CRUD

    @discardableResult
    func createGroup(name: String, color: String? = nil) -> CardGroup? {
        let group = CardGroup(
            id: UUID().uuidString,
            name: name,
            color: color ?? Self.palette[groups.count % Self.palette.count],
            sortOrder: (groups.map(\.sortOrder).max() ?? -1) + 1)
        do {
            try database.queue.write { db in
                try db.execute(
                    sql: "INSERT INTO card_group (id, name, color, sort_order, created_at) VALUES (?,?,?,?,?)",
                    arguments: [group.id, group.name, group.color, group.sortOrder, Date().timeIntervalSince1970])
            }
            groups.append(group)
            membersByGroup[group.id] = []
            bump()
            return group
        } catch {
            Self.logger.error("createGroup failed: \(String(describing: error))")
            return nil
        }
    }

    func renameGroup(_ id: String, to name: String) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        write("UPDATE card_group SET name = ? WHERE id = ?", [name, id])
        groups[i].name = name
        bump()
    }

    func deleteGroup(_ id: String) {
        write("DELETE FROM card_group WHERE id = ?", [id])  // cascades members
        groups.removeAll { $0.id == id }
        membersByGroup[id] = nil
        bump()
    }

    // MARK: Membership

    func isMember(_ ref: CardRef, of groupID: String) -> Bool {
        membersByGroup[groupID]?.contains(ref) ?? false
    }

    func groups(for ref: CardRef) -> [CardGroup] {
        groups.filter { membersByGroup[$0.id]?.contains(ref) ?? false }
    }

    func members(of groupID: String) -> [CardRef] {
        Array(membersByGroup[groupID] ?? [])
    }

    func memberCount(_ groupID: String) -> Int { membersByGroup[groupID]?.count ?? 0 }

    func setMember(_ ref: CardRef, group groupID: String, member: Bool) {
        if member {
            write("INSERT OR IGNORE INTO group_member (group_id, card_id, variant) VALUES (?,?,?)",
                  [groupID, ref.cardID, ref.variant.rawValue])
            membersByGroup[groupID, default: []].insert(ref)
        } else {
            write("DELETE FROM group_member WHERE group_id = ? AND card_id = ? AND variant = ?",
                  [groupID, ref.cardID, ref.variant.rawValue])
            membersByGroup[groupID]?.remove(ref)
        }
        bump()
    }

    @discardableResult
    func toggle(_ ref: CardRef, group groupID: String) -> Bool {
        let next = !isMember(ref, of: groupID)
        setMember(ref, group: groupID, member: next)
        return next
    }

    // MARK: Helpers

    private func write(_ sql: String, _ args: [DatabaseValueConvertible]) {
        do { try database.queue.write { db in try db.execute(sql: sql, arguments: StatementArguments(args)) } }
        catch { Self.logger.error("group write failed: \(String(describing: error))") }
    }

    private func bump() { changeToken &+= 1 }
}
