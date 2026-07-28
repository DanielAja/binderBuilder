//
//  TradeListStore.swift
//  binderBuilder
//
//  The "for trade" list: cards the user is willing to trade away at a show,
//  each with an asking value (market / % of market / fixed). In-memory mirror
//  of `trade_list` for synchronous UI; cheap init + async `load()`.
//

import Foundation
import Observation
import os

@MainActor @Observable final class TradeListStore {
    @ObservationIgnored private let database: UserDatabase

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.aja.binderBuilder", category: "TradeListStore")

    /// For-trade listings, newest first.
    private(set) var listings: [TradeListing] = []
    private(set) var changeToken: Int = 0

    init(database: UserDatabase) {
        self.database = database
    }

    func load() async {
        do {
            listings = try await database.allTradeListings()
            changeToken &+= 1
        } catch {
            Self.logger.error("failed to load trade list: \(String(describing: error))")
        }
    }

    var count: Int { listings.count }

    var refs: Set<CardRef> { Set(listings.map(\.ref)) }

    func isListed(_ ref: CardRef) -> Bool { listings.contains { $0.ref == ref } }

    func listing(id: String) -> TradeListing? { listings.first { $0.id == id } }

    /// First listing for a printing (used by detail-screen toggles).
    func listing(for ref: CardRef) -> TradeListing? { listings.first { $0.ref == ref } }

    @discardableResult
    func save(_ listing: TradeListing) -> Bool {
        do {
            try database.upsertTradeListing(listing)
            if let i = listings.firstIndex(where: { $0.id == listing.id }) {
                listings[i] = listing
            } else {
                listings.insert(listing, at: 0)
            }
            listings.sort { $0.addedAt > $1.addedAt }
            bump()
            return true
        } catch {
            Self.logger.error("save listing failed: \(String(describing: error))")
            return false
        }
    }

    func remove(id: String) {
        do {
            try database.deleteTradeListing(id: id)
            listings.removeAll { $0.id == id }
            bump()
        } catch {
            Self.logger.error("remove listing failed: \(String(describing: error))")
        }
    }

    /// Adds a printing to the for-trade list if not already there, else removes
    /// every listing of it. Returns the new listed state.
    @discardableResult
    func toggle(_ ref: CardRef, condition: CardCondition = .nm) -> Bool {
        if let existing = listing(for: ref) {
            remove(id: existing.id)
            return false
        }
        save(TradeListing(ref: ref, condition: condition))
        return true
    }

    private func bump() { changeToken &+= 1 }
}
