//
//  AlertStore.swift
//  binderBuilder
//
//  Per-printing price alerts (notify when a card drops below a target price,
//  or by a percentage from a baseline) + the "known sets" baseline used to
//  detect new releases. Mirrors price_alert / known_set in memory.
//

import Foundation
import GRDB
import Observation
import os

nonisolated enum AlertKind: String, Codable, CaseIterable, Sendable {
    case belowTarget   // threshold = target price
    case percentDrop   // threshold = percent; baseline = price when set
}

nonisolated struct PriceAlert: Identifiable, Hashable, Sendable {
    var ref: CardRef
    var kind: AlertKind
    var threshold: Double
    var baseline: Double?
    var id: String { "\(ref.cardID)|\(ref.variant.rawValue)" }
}

@MainActor @Observable final class AlertStore {
    private let database: UserDatabase

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.aja.binderBuilder", category: "AlertStore")

    private(set) var alerts: [CardRef: PriceAlert] = [:]
    private(set) var changeToken = 0

    init(database: UserDatabase) {
        self.database = database
        do {
            try database.queue.read { db in
                for row in try Row.fetchAll(db, sql: "SELECT card_id, variant, kind, threshold, baseline FROM price_alert") {
                    guard let variant = CardVariant(rawValue: row["variant"] as String? ?? ""),
                          let kind = AlertKind(rawValue: row["kind"] as String? ?? "") else { continue }
                    let ref = CardRef(cardID: row["card_id"], variant: variant)
                    alerts[ref] = PriceAlert(ref: ref, kind: kind, threshold: row["threshold"], baseline: row["baseline"])
                }
            }
        } catch {
            Self.logger.error("failed to load alerts: \(String(describing: error))")
        }
    }

    func alert(for ref: CardRef) -> PriceAlert? { alerts[ref] }
    var all: [PriceAlert] { Array(alerts.values) }

    func setAlert(_ ref: CardRef, kind: AlertKind, threshold: Double, baseline: Double?) {
        let alert = PriceAlert(ref: ref, kind: kind, threshold: threshold, baseline: baseline)
        do {
            try database.queue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO price_alert (card_id, variant, kind, threshold, baseline, created_at)
                    VALUES (?,?,?,?,?,?)
                    ON CONFLICT(card_id, variant) DO UPDATE SET kind=excluded.kind, threshold=excluded.threshold, baseline=excluded.baseline
                    """,
                    arguments: [ref.cardID, ref.variant.rawValue, kind.rawValue, threshold, baseline, Date().timeIntervalSince1970])
            }
            alerts[ref] = alert
            changeToken &+= 1
        } catch { Self.logger.error("setAlert failed: \(String(describing: error))") }
    }

    func removeAlert(_ ref: CardRef) {
        do {
            try database.queue.write { db in
                try db.execute(sql: "DELETE FROM price_alert WHERE card_id=? AND variant=?",
                               arguments: [ref.cardID, ref.variant.rawValue])
            }
            alerts[ref] = nil
            changeToken &+= 1
        } catch { Self.logger.error("removeAlert failed: \(String(describing: error))") }
    }
}

extension UserDatabase {
    func knownSetIDs() -> Set<String> {
        (try? queue.read { db in Set(try String.fetchAll(db, sql: "SELECT set_id FROM known_set")) }) ?? []
    }
    func addKnownSets(_ ids: [String]) {
        try? queue.write { db in
            for id in ids {
                try db.execute(sql: "INSERT OR IGNORE INTO known_set (set_id) VALUES (?)", arguments: [id])
            }
        }
    }
}
