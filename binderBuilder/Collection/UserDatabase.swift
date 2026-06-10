//
//  UserDatabase.swift
//  binderBuilder
//
//  The user's mutable database (owned cards, binders, slot assignments,
//  display case, price cache). Lives at Application Support/user.sqlite;
//  tests use an injectable path or a pure in-memory queue.
//

import Foundation
import GRDB

nonisolated final class UserDatabase: Sendable {
    /// Internal so stores (and tests via @testable) can read/write directly.
    let queue: DatabaseQueue

    /// Opens (and migrates) a database file at the given path.
    convenience init(path: String) throws {
        try self.init(queue: DatabaseQueue(path: path, configuration: Self.configuration))
    }

    /// In-memory database for unit tests.
    static func inMemory() throws -> UserDatabase {
        try UserDatabase(queue: DatabaseQueue(configuration: configuration))
    }

    /// The production database at Application Support/user.sqlite.
    static func openDefault() throws -> UserDatabase {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        return try UserDatabase(path: directory.appendingPathComponent("user.sqlite").path)
    }

    private init(queue: DatabaseQueue) throws {
        self.queue = queue
        try Self.migrator.migrate(queue)
    }

    private static var configuration: Configuration {
        var configuration = Configuration()
        // GRDB enables foreign keys by default; make the cascade-delete
        // contract (slot_assignment -> binder) explicit.
        configuration.foreignKeysEnabled = true
        return configuration
    }

    /// Schema migrations (raw SQL so they match the fixed contract exactly).
    /// Internal so tests can run partial migrations.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE owned_card (
                  card_id TEXT NOT NULL, variant TEXT NOT NULL,
                  quantity INTEGER NOT NULL DEFAULT 1, added_at REAL NOT NULL,
                  PRIMARY KEY (card_id, variant)
                );
                CREATE TABLE binder (
                  id TEXT PRIMARY KEY, name TEXT NOT NULL, cover_color TEXT NOT NULL,
                  page_count INTEGER NOT NULL DEFAULT 10, sort_order INTEGER NOT NULL, created_at REAL NOT NULL
                );
                CREATE TABLE slot_assignment (
                  binder_id TEXT NOT NULL REFERENCES binder(id) ON DELETE CASCADE,
                  page_index INTEGER NOT NULL, side INTEGER NOT NULL, slot_index INTEGER NOT NULL,
                  card_id TEXT NOT NULL, variant TEXT NOT NULL,
                  PRIMARY KEY (binder_id, page_index, side, slot_index)
                );
                CREATE TABLE display_case (
                  position INTEGER PRIMARY KEY, card_id TEXT NOT NULL, variant TEXT NOT NULL
                );
                CREATE TABLE price_cache (
                  card_id TEXT NOT NULL, source TEXT NOT NULL, variant TEXT NOT NULL,
                  currency TEXT NOT NULL, market REAL, low REAL, fetched_at REAL NOT NULL,
                  PRIMARY KEY (card_id, source, variant)
                );
                """)
        }
        // v2 — per-copy ownership (condition + grade), wishlist, value trend.
        migrator.registerMigration("v2") { db in
            try db.execute(sql: """
                CREATE TABLE card_copy (
                  id TEXT PRIMARY KEY,
                  card_id TEXT NOT NULL, variant TEXT NOT NULL,
                  condition TEXT NOT NULL DEFAULT 'NM',
                  grade_company TEXT, grade_value REAL,
                  acquired_price REAL, acquired_at REAL NOT NULL,
                  notes TEXT
                );
                CREATE INDEX idx_copy_card ON card_copy(card_id, variant);
                CREATE TABLE wishlist (
                  card_id TEXT NOT NULL, variant TEXT NOT NULL, added_at REAL NOT NULL,
                  PRIMARY KEY (card_id, variant)
                );
                CREATE TABLE value_snapshot (day TEXT PRIMARY KEY, total REAL NOT NULL);
                """)
            // Expand each owned_card row's quantity into N raw (NM) copies.
            let owned = try Row.fetchAll(db, sql: "SELECT card_id, variant, quantity, added_at FROM owned_card")
            for row in owned {
                let cardID: String = row["card_id"]
                let variant: String = row["variant"]
                let quantity: Int = row["quantity"]
                let addedAt: Double = row["added_at"]
                for _ in 0..<max(1, quantity) {
                    try db.execute(
                        sql: """
                        INSERT INTO card_copy (id, card_id, variant, condition, acquired_at)
                        VALUES (?, ?, ?, 'NM', ?)
                        """,
                        arguments: [UUID().uuidString, cardID, variant, addedAt])
                }
            }
            try db.execute(sql: "DROP TABLE owned_card")
        }
        // v3 — custom collection groups + alert/sync support tables.
        migrator.registerMigration("v3") { db in
            try db.execute(sql: """
                CREATE TABLE card_group (
                  id TEXT PRIMARY KEY, name TEXT NOT NULL, color TEXT NOT NULL,
                  sort_order INTEGER NOT NULL, created_at REAL NOT NULL
                );
                CREATE TABLE group_member (
                  group_id TEXT NOT NULL REFERENCES card_group(id) ON DELETE CASCADE,
                  card_id TEXT NOT NULL, variant TEXT NOT NULL,
                  PRIMARY KEY (group_id, card_id, variant)
                );
                CREATE TABLE price_alert (
                  card_id TEXT NOT NULL, variant TEXT NOT NULL,
                  kind TEXT NOT NULL, threshold REAL NOT NULL, baseline REAL,
                  created_at REAL NOT NULL,
                  PRIMARY KEY (card_id, variant)
                );
                CREATE TABLE known_set (set_id TEXT PRIMARY KEY);
                """)
        }
        return migrator
    }
}
