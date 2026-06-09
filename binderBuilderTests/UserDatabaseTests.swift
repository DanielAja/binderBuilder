//
//  UserDatabaseTests.swift
//  binderBuilderTests
//

import Foundation
import GRDB
import Testing
@testable import binderBuilder

struct UserDatabaseTests {
    @Test func v1MigrationCreatesTheContractTables() throws {
        let user = try UserDatabase.inMemory()
        let tables = try user.queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'grdb_%' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        }
        #expect(tables == ["binder", "display_case", "owned_card", "price_cache", "slot_assignment"])
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
                    sql: "INSERT INTO owned_card (card_id, variant, quantity, added_at) VALUES ('base1-4', 'holo', 1, 0)")
            }
        }
        // Re-opening runs the migrator idempotently and keeps the data.
        let reopened = try UserDatabase(path: path)
        let count = try reopened.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM owned_card") ?? 0
        }
        #expect(count == 1)
    }
}
