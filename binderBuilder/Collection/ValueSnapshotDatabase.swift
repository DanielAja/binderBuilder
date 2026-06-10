//
//  ValueSnapshotDatabase.swift
//  binderBuilder
//
//  Daily portfolio-value trend: one row per calendar day (latest total wins).
//  Cheap value-over-time without per-card price history.
//

import Foundation
import GRDB

extension UserDatabase {
    /// Records today's total collection value (idempotent per day).
    func recordValueSnapshot(total: Double, day: String) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO value_snapshot (day, total) VALUES (?, ?)
                ON CONFLICT(day) DO UPDATE SET total = excluded.total
                """,
                arguments: [day, total])
        }
    }

    /// The most recent `limit` snapshots, oldest → newest.
    func valueSnapshots(limit: Int = 60) throws -> [(day: String, total: Double)] {
        try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT day, total FROM value_snapshot ORDER BY day DESC LIMIT ?",
                arguments: [limit])
            return rows.reversed().map { (day: $0["day"], total: $0["total"]) }
        }
    }
}
