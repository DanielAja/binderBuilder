//
//  UserDatabaseTests.swift
//  binderBuilderTests
//

import Foundation
import GRDB
import Testing
@testable import binderBuilder

struct UserDatabaseTests {
    @Test func migrationCreatesTheContractTables() throws {
        let user = try UserDatabase.inMemory()
        let tables = try user.queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'grdb_%' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        }
        #expect(tables == ["binder", "card_copy", "card_group", "display_case", "group_member",
                           "known_set", "price_alert", "price_cache", "slot_assignment",
                           "value_snapshot", "wishlist"])
    }

    @Test func foreignKeysAreEnforced() throws {
        let user = try UserDatabase.inMemory()
        // Inserting a slot_assignment for a nonexistent binder must fail.
        #expect(throws: DatabaseError.self) {
            try user.queue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO slot_assignment (binder_id, page_index, side, slot_index, card_id, variant)
                    VALUES ('ghost', 0, 0, 0, 'base1-4', 'holo')
                    """)
            }
        }
    }

    @Test func fileBackedDatabaseMigratesAndReopens() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("user-test-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        do {
            let user = try UserDatabase(path: path)
            try user.queue.write { db in
                try db.execute(
                    sql: "INSERT INTO card_copy (id, card_id, variant, condition, acquired_at) VALUES ('c1', 'base1-4', 'holo', 'NM', 0)")
            }
        }
        // Re-opening runs the migrator idempotently and keeps the data.
        let reopened = try UserDatabase(path: path)
        let count = try reopened.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM card_copy") ?? 0
        }
        #expect(count == 1)
    }

    @Test func v2ExpandsOwnedCardQuantitiesIntoRawCopies() throws {
        let queue = try DatabaseQueue()
        // Migrate only up to v1, seed legacy owned_card with quantities.
        try UserDatabase.migrator.migrate(queue, upTo: "v1")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO owned_card (card_id, variant, quantity, added_at) VALUES ('base1-4', 'holo', 3, 100)")
            try db.execute(sql: "INSERT INTO owned_card (card_id, variant, quantity, added_at) VALUES ('base1-2', 'normal', 1, 200)")
        }
        // Run v2: owned_card -> card_copy (one row per copy), then dropped.
        try UserDatabase.migrator.migrate(queue)
        try queue.read { db in
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM card_copy") ?? 0
            #expect(total == 4) // 3 + 1
            let charizard = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM card_copy WHERE card_id = 'base1-4' AND variant = 'holo'") ?? 0
            #expect(charizard == 3)
            let allNM = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM card_copy WHERE condition = 'NM'") ?? 0
            #expect(allNM == 4)
            let ownedExists = try Bool.fetchOne(
                db, sql: "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='owned_card'") ?? true
            #expect(ownedExists == false)
        }
    }
}
