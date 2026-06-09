//
//  TestSupport.swift
//  binderBuilderTests
//
//  In-memory catalog fixture matching the catalog.sqlite schema contract
//  (schema_version 1), seeded with 8 cards across 2 sets.
//

import Foundation
import GRDB
@testable import binderBuilder

enum TestCatalog {
    /// The exact catalog.sqlite schema contract.
    static let schemaSQL = """
        CREATE TABLE set_info (
          id TEXT PRIMARY KEY, name TEXT NOT NULL,
          series_id TEXT, series_name TEXT,
          card_count_official INTEGER, card_count_total INTEGER,
          release_date TEXT, symbol_url TEXT, logo_url TEXT
        );
        CREATE TABLE card (
          id TEXT PRIMARY KEY, set_id TEXT NOT NULL REFERENCES set_info(id),
          name TEXT NOT NULL, local_number TEXT NOT NULL, sort_number INTEGER,
          category TEXT, rarity TEXT, types TEXT, hp INTEGER, illustrator TEXT,
          image_base TEXT,
          has_normal INTEGER NOT NULL DEFAULT 0, has_holo INTEGER NOT NULL DEFAULT 0,
          has_reverse INTEGER NOT NULL DEFAULT 0, has_first_edition INTEGER NOT NULL DEFAULT 0,
          regulation_mark TEXT
        );
        CREATE INDEX idx_card_set ON card(set_id, sort_number);
        CREATE INDEX idx_card_name ON card(name COLLATE NOCASE);
        CREATE VIRTUAL TABLE card_fts USING fts5(
          card_id UNINDEXED, name, set_name, local_number,
          tokenize='unicode61 remove_diacritics 2', prefix='2 3 4'
        );
        CREATE TABLE price_snapshot (
          card_id TEXT NOT NULL REFERENCES card(id),
          source TEXT NOT NULL, variant TEXT NOT NULL, currency TEXT NOT NULL,
          market REAL, low REAL, mid REAL, high REAL, updated_at TEXT,
          PRIMARY KEY (card_id, source, variant)
        );
        CREATE TABLE card_hash (
          card_id TEXT NOT NULL REFERENCES card(id),
          orientation INTEGER NOT NULL,
          dhash BLOB NOT NULL,
          phash BLOB NOT NULL,
          PRIMARY KEY (card_id, orientation)
        );
        CREATE TABLE catalog_meta (key TEXT PRIMARY KEY, value TEXT);
        """

    /// (id, setID, name, localNumber, sortNumber, category, rarity, types,
    ///  hp, illustrator, imageBase, hasNormal, hasHolo, hasReverse,
    ///  hasFirstEdition, regulationMark)
    private static let cards: [[DatabaseValueConvertible?]] = [
        ["base1-4", "base1", "Charizard", "4", 4, "Pokemon", "Rare Holo", "Fire", 120,
         "Mitsuhiro Arita", "https://assets.tcgdex.net/en/base/base1/4", 0, 1, 0, 1, nil],
        ["base1-24", "base1", "Charmeleon", "24", 24, "Pokemon", "Uncommon", "Fire", 80,
         "Mitsuhiro Arita", "https://assets.tcgdex.net/en/base/base1/24", 1, 0, 0, 1, nil],
        ["base1-46", "base1", "Charmander", "46", 46, "Pokemon", "Common", "Fire", 50,
         "Mitsuhiro Arita", "https://assets.tcgdex.net/en/base/base1/46", 1, 0, 0, 1, nil],
        // image_base intentionally NULL (round-trip test).
        ["base1-58", "base1", "Pikachu", "58", 58, "Pokemon", "Common", "Lightning", 40,
         "Mitsuhiro Arita", nil, 1, 0, 0, 1, nil],
        ["base1-102", "base1", "Water Energy", "102", 102, "Energy", "Common", nil, nil,
         "Keiji Kinebuchi", "https://assets.tcgdex.net/en/base/base1/102", 1, 0, 0, 1, nil],
        ["swsh9-1", "swsh9", "Exeggcute", "1", 1, "Pokemon", "Common", "Grass", 50,
         "Mizue", "https://assets.tcgdex.net/en/swsh/swsh9/1", 1, 0, 1, 0, "F"],
        ["swsh9-25", "swsh9", "Lumineon V", "25", 25, "Pokemon", "Ultra Rare", "Water", 170,
         "5ban Graphics", "https://assets.tcgdex.net/en/swsh/swsh9/25", 0, 1, 0, 0, "F"],
        // Trainer-gallery style local number "TG12" (non-numeric localId).
        ["swsh9-TG12", "swsh9", "Mew", "TG12", 198, "Pokemon", "Rare Holo", "Psychic", 60,
         "Kagemaru Himeno", "https://assets.tcgdex.net/en/swsh/swsh9/TG12", 0, 1, 0, 0, "F"],
    ]

    static func makeQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: schemaSQL)
            try seed(db)
        }
        return queue
    }

    static func makeCatalog() throws -> GRDBCatalogDatabase {
        GRDBCatalogDatabase(reader: try makeQueue())
    }

    private static func seed(_ db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO set_info VALUES
              ('base1', 'Base Set', 'base', 'Base', 102, 102, '1999-01-09',
               'https://assets.tcgdex.net/en/base/base1/symbol',
               'https://assets.tcgdex.net/en/base/base1/logo'),
              ('swsh9', 'Brilliant Stars', 'swsh', 'Sword & Shield', 172, 186, '2022-02-25',
               'https://assets.tcgdex.net/en/swsh/swsh9/symbol',
               'https://assets.tcgdex.net/en/swsh/swsh9/logo')
            """)

        for card in cards {
            try db.execute(
                sql: """
                INSERT INTO card (id, set_id, name, local_number, sort_number, category,
                                  rarity, types, hp, illustrator, image_base,
                                  has_normal, has_holo, has_reverse, has_first_edition,
                                  regulation_mark)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: StatementArguments(card))
            let setName = card[1] as! String == "base1" ? "Base Set" : "Brilliant Stars"
            try db.execute(
                sql: "INSERT INTO card_fts (card_id, name, set_name, local_number) VALUES (?, ?, ?, ?)",
                arguments: [card[0] as! String, card[2] as! String, setName, card[3] as! String])
        }

        try db.execute(
            sql: """
            INSERT INTO price_snapshot (card_id, source, variant, currency, market, low, mid, high, updated_at) VALUES
              ('base1-4', 'tcgplayer', 'holo', 'USD', 420.5, 350.0, 400.0, 999.0, '2026-06-01T12:00:00Z'),
              ('base1-4', 'cardmarket', 'holo', 'EUR', 380.25, 300.0, 360.0, 900.0, '2026-06-01T12:00:00Z'),
              ('base1-4', 'tcgplayer', 'firstEdition', 'USD', 5200.0, 4100.0, 5000.0, 9000.0, '2026-06-01T12:00:00Z'),
              ('base1-4', 'someFutureSource', 'holo', 'USD', 1.0, 1.0, 1.0, 1.0, '2026-06-01T12:00:00Z'),
              ('base1-4', 'tcgplayer', 'someFutureVariant', 'USD', 1.0, 1.0, 1.0, 1.0, '2026-06-01T12:00:00Z'),
              ('swsh9-1', 'tcgplayer', 'reverse', 'USD', 0.25, 0.05, 0.2, 2.0, '2026-06-01T12:00:00Z')
            """)

        // 4 orientations of a fake 64-bit dhash/phash for Charizard.
        for orientation in [0, 90, 180, 270] {
            let dhash = Data((0..<8).map { UInt8($0 + orientation / 10) })
            let phash = Data((0..<8).map { UInt8(255 - $0 - orientation / 10) })
            try db.execute(
                sql: "INSERT INTO card_hash (card_id, orientation, dhash, phash) VALUES (?, ?, ?, ?)",
                arguments: ["base1-4", orientation, dhash, phash])
        }

        try db.execute(
            sql: """
            INSERT INTO catalog_meta VALUES
              ('schema_version', '1'), ('build_date', '2026-06-01T12:00:00Z'),
              ('card_count', '8'), ('set_count', '2')
            """)
    }
}

/// Dictionary-backed keychain double (the real keychain is flaky in
/// headless simulator test runs).
nonisolated final class FakeKeychain: KeychainStoring {
    var storage: [String: String] = [:]

    func string(for key: String) -> String? { storage[key] }
    func set(_ value: String, for key: String) { storage[key] = value }
    func delete(key: String) { storage[key] = nil }
}
