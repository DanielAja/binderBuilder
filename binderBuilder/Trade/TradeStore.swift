//
//  TradeStore.swift
//  binderBuilder
//
//  The trade log: an in-memory mirror of the `trade` + `trade_item` tables for
//  synchronous UI, with running profit/loss. Follows the store contract — cheap
//  init, `load()` off the main thread from AppEnvironment.prepare(),
//  `changeToken` bumps on mutation.
//

import Foundation
import Observation
import os

@MainActor @Observable final class TradeStore {
    @ObservationIgnored private let database: UserDatabase

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.aja.binderBuilder", category: "TradeStore")

    /// All logged trades, newest first.
    private(set) var trades: [Trade] = []
    private(set) var changeToken: Int = 0

    init(database: UserDatabase) {
        self.database = database
    }

    func load() async {
        do {
            trades = try await database.allTrades()
            changeToken &+= 1
        } catch {
            Self.logger.error("failed to load trades: \(String(describing: error))")
        }
    }

    var count: Int { trades.count }

    /// Running net value across every trade (received − given, cards + cash).
    var totalNetValue: Double { trades.reduce(0) { $0 + $1.netValue } }

    /// Total value of cards the user has received / given across all trades.
    var totalReceivedValue: Double { trades.reduce(0) { $0 + $1.valueIn } }
    var totalGivenValue: Double { trades.reduce(0) { $0 + $1.valueOut } }

    /// Distinct events the user has traded at, most recent first (for the
    /// convention picker / autocompletion).
    var recentEvents: [String] {
        var seen = Set<String>()
        return trades.compactMap { trade -> String? in
            guard let event = trade.event?.trimmingCharacters(in: .whitespaces), !event.isEmpty,
                  seen.insert(event).inserted else { return nil }
            return event
        }
    }

    func trade(id: String) -> Trade? { trades.first { $0.id == id } }

    @discardableResult
    func save(_ trade: Trade) -> Bool {
        do {
            try database.upsertTrade(trade)
            if let i = trades.firstIndex(where: { $0.id == trade.id }) {
                trades[i] = trade
            } else {
                trades.append(trade)
            }
            trades.sort { ($0.date, $0.createdAt) > ($1.date, $1.createdAt) }
            bump()
            return true
        } catch {
            Self.logger.error("save trade failed: \(String(describing: error))")
            return false
        }
    }

    func delete(id: String) {
        do {
            try database.deleteTrade(id: id)
            trades.removeAll { $0.id == id }
            bump()
        } catch {
            Self.logger.error("delete trade failed: \(String(describing: error))")
        }
    }

    private func bump() { changeToken &+= 1 }
}
