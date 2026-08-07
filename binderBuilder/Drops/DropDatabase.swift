//
//  DropDatabase.swift
//  binderBuilder
//
//  Drop-specific reads/writes over the shared user database (v6's
//  drop_subscription, plus the favorite_store count the reminder copy needs).
//  Kept out of UserDatabase.swift so the schema file stays shared/neutral.
//
//  drop_subscription stores deviations only: a missing row means subscribed.
//

import Foundation
import GRDB

nonisolated extension UserDatabase {
    /// Per-release opt-outs (and explicit opt-ins), keyed by release id.
    /// Releases absent from the map are subscribed.
    func dropSubscriptions() -> [String: Bool] {
        let rows = (try? queue.read { db in
            try Row.fetchAll(db, sql: "SELECT release_id, enabled FROM drop_subscription")
        }) ?? []
        return Dictionary(uniqueKeysWithValues: rows.map { row in
            (row["release_id"] as String, (row["enabled"] as Int) != 0)
        })
    }

    /// Records a deviation for one release. Writing `true` keeps an explicit
    /// row so a re-subscribe survives a later default change.
    func setDropSubscription(_ releaseID: String, enabled: Bool) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO drop_subscription (release_id, enabled, created_at) VALUES (?,?,?)
                ON CONFLICT(release_id) DO UPDATE SET enabled = excluded.enabled
                """,
                arguments: [releaseID, enabled ? 1 : 0, Date().timeIntervalSince1970])
        }
    }

    /// How many stores the user saved — only used to colour the day-before copy.
    func dropFavoriteStoreCount() -> Int {
        (try? queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM favorite_store") ?? 0
        }) ?? 0
    }
}
