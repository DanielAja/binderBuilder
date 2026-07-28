//
//  FavoriteStoreStore.swift
//  binderBuilder
//
//  The user's saved local/big-box stores (favorite_store), used to scope
//  drop-radius notifications and to count toward the t1 reminder's "mentions
//  favorite-store count unless 0" copy. Mirrors the table in memory;
//  `changeToken` bumps on mutation.
//

import Foundation
import GRDB
import Observation
import os

nonisolated struct FavoriteStore: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var address: String?
    var latitude: Double
    var longitude: Double
    var kind: StoreKind
    var addedAt: Date
}

@MainActor @Observable final class FavoriteStoreStore {
    private let database: UserDatabase

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.aja.binderBuilder", category: "FavoriteStoreStore")

    /// Ordered oldest-added first (the order the user built their list in).
    private(set) var stores: [FavoriteStore] = []
    private(set) var changeToken = 0

    init(database: UserDatabase) {
        self.database = database
    }

    /// Loads the in-memory mirror off the main thread (from prepare()).
    func load() async {
        do {
            stores = try await database.allFavoriteStores()
            changeToken &+= 1
        } catch {
            Self.logger.error("failed to load favorite stores: \(String(describing: error))")
        }
    }

    /// Exposed for the drop-reminder scheduler (t1 copy mentions this count).
    var count: Int { stores.count }

    func isFavorite(_ id: String) -> Bool { stores.contains { $0.id == id } }

    /// Adds a nearby search result as a favorite (idempotent by id).
    @discardableResult
    func add(_ nearby: NearbyStore) -> FavoriteStore? {
        if let existing = stores.first(where: { $0.id == nearby.id }) { return existing }
        let store = FavoriteStore(
            id: nearby.id, name: nearby.name, address: nearby.address,
            latitude: nearby.latitude, longitude: nearby.longitude,
            kind: nearby.kind, addedAt: Date())
        do {
            try database.upsertFavoriteStore(store)
            stores.append(store)
            changeToken &+= 1
            return store
        } catch {
            Self.logger.error("add favorite store failed: \(String(describing: error))")
            return nil
        }
    }

    func remove(id: String) {
        do {
            try database.deleteFavoriteStore(id: id)
            stores.removeAll { $0.id == id }
            changeToken &+= 1
        } catch {
            Self.logger.error("remove favorite store failed: \(String(describing: error))")
        }
    }
}

extension UserDatabase {
    /// Ordered by added_at ascending (oldest first).
    func allFavoriteStores() async throws -> [FavoriteStore] {
        try await queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, name, address, latitude, longitude, kind, added_at
                FROM favorite_store ORDER BY added_at ASC
                """).compactMap { row -> FavoriteStore? in
                guard let kind = StoreKind(rawValue: row["kind"] as String? ?? "") else { return nil }
                return FavoriteStore(
                    id: row["id"], name: row["name"], address: row["address"],
                    latitude: row["latitude"], longitude: row["longitude"],
                    kind: kind, addedAt: Date(timeIntervalSince1970: row["added_at"]))
            }
        }
    }

    func upsertFavoriteStore(_ store: FavoriteStore) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO favorite_store (id, name, address, latitude, longitude, kind, added_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  name = excluded.name, address = excluded.address,
                  latitude = excluded.latitude, longitude = excluded.longitude,
                  kind = excluded.kind
                """,
                arguments: [store.id, store.name, store.address, store.latitude, store.longitude,
                            store.kind.rawValue, store.addedAt.timeIntervalSince1970])
        }
    }

    func deleteFavoriteStore(id: String) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM favorite_store WHERE id = ?", arguments: [id])
        }
    }
}
