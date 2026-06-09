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

    /// Schema v1 — raw SQL so it matches the fixed contract exactly.
    private static var migrator: DatabaseMigrator {
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
        return migrator
    }
}
