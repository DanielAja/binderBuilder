//
//  CatalogDatabase.swift
//  binderBuilder
//
//  Read-only access to the bundled catalog.sqlite (schema_version 1):
//  set_info, card, card_fts (FTS5), price_snapshot, card_hash, catalog_meta.
//

import Foundation
import GRDB
import os

/// Read-only catalog queries. Implemented by GRDBCatalogDatabase in
/// production and by test doubles in unit tests.
nonisolated protocol CatalogReading: Sendable {
    /// FTS5 prefix search over card name / set name / collector number,
    /// ranked by bm25 relevance.
    func searchCards(matching query: String, limit: Int) async throws -> [CardSummary]
    /// All cards of a set, ordered by sort_number.
    func cards(inSet setID: String) async throws -> [CardSummary]
    func card(id: String) async throws -> CardDetail?
    func allSets() async throws -> [SetInfo]
    /// Last-known prices baked into the catalog at build time (isLive=false).
    func bundledQuotes(for cardID: String) async throws -> [PriceQuote]
    /// Bundled perceptual-hash index (4 orientations per card) for the scanner.
    func hashEntries() async throws -> [(cardID: String, orientation: Int, dhash: Data, phash: Data)]
    /// Distinct owned-card count per set (set completion), given owned card IDs.
    func ownedCardCounts(forCardIDs cardIDs: [String]) async throws -> [String: Int]
    /// Rarity + type histograms over the given card IDs (collection stats).
    func cardFacets(forCardIDs cardIDs: [String]) async throws -> (rarities: [String: Int], types: [String: Int])
    /// Bundled TCGplayer market price per printing (instant collection value).
    func bundledMarket(for refs: [CardRef]) async throws -> [CardRef: Double]
    /// Card summaries for a set of IDs (e.g. the owned-cards grid).
    func summaries(forCardIDs cardIDs: [String]) async throws -> [CardSummary]
}

extension CatalogReading {
    /// Default: no hash index (test doubles); GRDBCatalogDatabase overrides.
    func hashEntries() async throws -> [(cardID: String, orientation: Int, dhash: Data, phash: Data)] { [] }
    func ownedCardCounts(forCardIDs cardIDs: [String]) async throws -> [String: Int] { [:] }
    func cardFacets(forCardIDs cardIDs: [String]) async throws -> (rarities: [String: Int], types: [String: Int]) { ([:], [:]) }
    func bundledMarket(for refs: [CardRef]) async throws -> [CardRef: Double] { [:] }
    func summaries(forCardIDs cardIDs: [String]) async throws -> [CardSummary] { [] }
}

nonisolated final class GRDBCatalogDatabase: CatalogReading {
    private let reader: any DatabaseReader

    private static let logger = Logger(subsystem: "com.aja.binderBuilder", category: "CatalogDatabase")

    /// Opens a catalog file read-only (the bundled catalog is immutable).
    init(path: String) throws {
        var configuration = Configuration()
        configuration.readonly = true
        self.reader = try DatabasePool(path: path, configuration: configuration)
    }

    /// Test seam: wrap an already-open database (e.g. an in-memory
    /// DatabaseQueue seeded with fixture rows).
    init(reader: any DatabaseReader) {
        self.reader = reader
    }

    /// The catalog shipped in the app bundle, or nil when it is absent.
    /// The app must keep working without it (search/sets simply unavailable).
    static func bundled() -> GRDBCatalogDatabase? {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "sqlite") else {
            logger.warning("catalog.sqlite not found in app bundle; running without a card catalog")
            return nil
        }
        do {
            return try GRDBCatalogDatabase(path: url.path)
        } catch {
            logger.error("failed to open bundled catalog.sqlite: \(String(describing: error))")
            return nil
        }
    }

    // MARK: - CatalogReading

    func searchCards(matching query: String, limit: Int) async throws -> [CardSummary] {
        guard let match = Self.ftsMatchExpression(for: query) else { return [] }
        return try await reader.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT \(Self.summaryColumns)
                FROM card_fts
                JOIN card ON card.id = card_fts.card_id
                JOIN set_info ON set_info.id = card.set_id
                WHERE card_fts MATCH ?
                ORDER BY bm25(card_fts)
                LIMIT ?
                """,
                arguments: [match, limit])
            return rows.map(Self.summary(from:))
        }
    }

    func cards(inSet setID: String) async throws -> [CardSummary] {
        try await reader.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT \(Self.summaryColumns)
                FROM card
                JOIN set_info ON set_info.id = card.set_id
                WHERE card.set_id = ?
                ORDER BY card.sort_number IS NULL, card.sort_number, card.local_number
                """,
                arguments: [setID])
            return rows.map(Self.summary(from:))
        }
    }

    func card(id: String) async throws -> CardDetail? {
        try await reader.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT \(Self.summaryColumns),
                       card.category AS category, card.types AS types, card.hp AS hp,
                       card.illustrator AS illustrator, card.regulation_mark AS regulation_mark,
                       card.sort_number AS sort_number
                FROM card
                JOIN set_info ON set_info.id = card.set_id
                WHERE card.id = ?
                """,
                arguments: [id])
            return row.map { row in
                CardDetail(
                    summary: Self.summary(from: row),
                    category: row["category"],
                    types: Self.parseTypes(row["types"]),
                    hp: row["hp"],
                    illustrator: row["illustrator"],
                    regulationMark: row["regulation_mark"],
                    sortNumber: row["sort_number"] as Int? ?? 0)
            }
        }
    }

    func allSets() async throws -> [SetInfo] {
        try await reader.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, name, series_id, series_name, card_count_official,
                       card_count_total, release_date, symbol_url, logo_url
                FROM set_info
                ORDER BY release_date IS NULL, release_date, name
                """)
            return rows.map { row in
                SetInfo(
                    id: row["id"],
                    name: row["name"],
                    seriesID: row["series_id"],
                    seriesName: row["series_name"],
                    cardCountOfficial: row["card_count_official"],
                    cardCountTotal: row["card_count_total"],
                    releaseDate: row["release_date"],
                    symbolURL: row["symbol_url"],
                    logoURL: row["logo_url"])
            }
        }
    }

    func bundledQuotes(for cardID: String) async throws -> [PriceQuote] {
        try await reader.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT source, variant, currency, market, low, updated_at
                FROM price_snapshot
                WHERE card_id = ?
                """,
                arguments: [cardID])
            return rows.compactMap { row in
                // Rows with sources/variants this app version doesn't know are skipped.
                guard let source = PriceQuote.Source(rawValue: row["source"] as String? ?? ""),
                      let variant = CardVariant(rawValue: row["variant"] as String? ?? "")
                else { return nil }
                return PriceQuote(
                    source: source,
                    variant: variant,
                    currency: row["currency"] as String? ?? "USD",
                    market: row["market"],
                    low: row["low"],
                    fetchedAt: Self.parseISO8601(row["updated_at"]),
                    isLive: false)
            }
        }
    }

    // MARK: - Scanner support

    /// The full perceptual-hash index (dhash/phash per orientation), consumed
    /// by the scanner's Hamming-distance linear scan.
    func hashEntries() async throws -> [(cardID: String, orientation: Int, dhash: Data, phash: Data)] {
        try await reader.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT card_id, orientation, dhash, phash FROM card_hash")
            return rows.map { row in
                (cardID: row["card_id"] as String,
                 orientation: row["orientation"] as Int,
                 dhash: row["dhash"] as Data,
                 phash: row["phash"] as Data)
            }
        }
    }

    // MARK: - Collection aggregates

    /// SQLite parameter-count safety: query owned-ID lists in chunks.
    private static let chunkSize = 900

    func ownedCardCounts(forCardIDs cardIDs: [String]) async throws -> [String: Int] {
        guard !cardIDs.isEmpty else { return [:] }
        return try await reader.read { db in
            var counts: [String: Int] = [:]
            for chunk in cardIDs.chunked(into: Self.chunkSize) {
                let placeholders = databaseQuestionMarks(count: chunk.count)
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT set_id, COUNT(*) AS c FROM card WHERE id IN (\(placeholders)) GROUP BY set_id",
                    arguments: StatementArguments(chunk))
                for row in rows { counts[row["set_id"], default: 0] += (row["c"] as Int? ?? 0) }
            }
            return counts
        }
    }

    func cardFacets(forCardIDs cardIDs: [String]) async throws -> (rarities: [String: Int], types: [String: Int]) {
        guard !cardIDs.isEmpty else { return ([:], [:]) }
        return try await reader.read { db in
            var rarities: [String: Int] = [:]
            var types: [String: Int] = [:]
            for chunk in cardIDs.chunked(into: Self.chunkSize) {
                let placeholders = databaseQuestionMarks(count: chunk.count)
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT rarity, types FROM card WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(chunk))
                for row in rows {
                    if let rarity = row["rarity"] as String?, !rarity.isEmpty {
                        rarities[rarity, default: 0] += 1
                    }
                    for type in Self.parseTypes(row["types"]) { types[type, default: 0] += 1 }
                }
            }
            return (rarities, types)
        }
    }

    func bundledMarket(for refs: [CardRef]) async throws -> [CardRef: Double] {
        guard !refs.isEmpty else { return [:] }
        let wanted = Set(refs)
        let cardIDs = Array(Set(refs.map(\.cardID)))
        return try await reader.read { db in
            var out: [CardRef: Double] = [:]
            for chunk in cardIDs.chunked(into: Self.chunkSize) {
                let placeholders = databaseQuestionMarks(count: chunk.count)
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT card_id, variant, market FROM price_snapshot
                    WHERE source = 'tcgplayer' AND market IS NOT NULL AND card_id IN (\(placeholders))
                    """,
                    arguments: StatementArguments(chunk))
                for row in rows {
                    guard let variant = CardVariant(rawValue: row["variant"] as String? ?? ""),
                          let market = row["market"] as Double? else { continue }
                    let ref = CardRef(cardID: row["card_id"], variant: variant)
                    if wanted.contains(ref) { out[ref] = market }
                }
            }
            return out
        }
    }

    func summaries(forCardIDs cardIDs: [String]) async throws -> [CardSummary] {
        guard !cardIDs.isEmpty else { return [] }
        return try await reader.read { db in
            var out: [CardSummary] = []
            for chunk in cardIDs.chunked(into: Self.chunkSize) {
                let placeholders = databaseQuestionMarks(count: chunk.count)
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT \(Self.summaryColumns)
                    FROM card
                    JOIN set_info ON set_info.id = card.set_id
                    WHERE card.id IN (\(placeholders))
                    """,
                    arguments: StatementArguments(chunk))
                out.append(contentsOf: rows.map(Self.summary(from:)))
            }
            return out
        }
    }

    // MARK: - Row mapping

    private static let summaryColumns = """
        card.id AS id, card.name AS name, card.set_id AS set_id,
        set_info.name AS set_name, card.local_number AS local_number,
        card.rarity AS rarity, card.image_base AS image_base,
        card.has_normal AS has_normal, card.has_holo AS has_holo,
        card.has_reverse AS has_reverse, card.has_first_edition AS has_first_edition
        """

    private static func summary(from row: Row) -> CardSummary {
        var variants: Set<CardVariant> = []
        if (row["has_normal"] as Int? ?? 0) != 0 { variants.insert(.normal) }
        if (row["has_holo"] as Int? ?? 0) != 0 { variants.insert(.holo) }
        if (row["has_reverse"] as Int? ?? 0) != 0 { variants.insert(.reverse) }
        if (row["has_first_edition"] as Int? ?? 0) != 0 { variants.insert(.firstEdition) }
        return CardSummary(
            id: row["id"],
            name: row["name"],
            setID: row["set_id"],
            setName: row["set_name"],
            localNumber: row["local_number"],
            rarity: row["rarity"],
            imageBase: row["image_base"],
            availableVariants: variants)
    }

    /// Builds an FTS5 MATCH expression where every whitespace-separated token
    /// becomes a quoted prefix term: `char 4` -> `"char"* "4"*` (implicit AND).
    /// Returns nil when the query has no usable tokens.
    private static func ftsMatchExpression(for query: String) -> String? {
        let tokens = query
            .split(whereSeparator: \.isWhitespace)
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    /// `card.types` is stored as TEXT; the catalog builder may use either a
    /// JSON array or a comma-separated list. Accept both.
    private static func parseTypes(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        if raw.hasPrefix("["),
           let array = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)) {
            return array
        }
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func parseISO8601(_ string: String?) -> Date {
        guard let string, !string.isEmpty else { return .distantPast }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: string) ?? .distantPast
    }
}

private extension Array {
    /// Splits into sub-arrays of at most `size` (for chunked SQL IN-lists).
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
