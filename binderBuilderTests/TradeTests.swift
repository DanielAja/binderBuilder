//
//  TradeTests.swift
//  binderBuilderTests
//
//  Trade value math, trade log + for-trade stores, wishlist targets, the
//  single "trading price" resolver, the fast-scanner stabilizer/crop, the v5
//  migration, and backup round-tripping of the new tables.
//

import CoreGraphics
import Foundation
import GRDB
import Testing
@testable import binderBuilder

// MARK: - TradeValue

struct TradeValueTests {
    @Test func resolvesAgainstMarket() {
        #expect(TradeValue.market.resolve(market: 40) == 40)
        #expect(TradeValue.market.resolve(market: nil) == nil)
        #expect(TradeValue.percentOfMarket(90).resolve(market: 100) == 90)
        #expect(TradeValue.percentOfMarket(80).resolve(market: nil) == nil)
        #expect(TradeValue.fixed(12.5).resolve(market: nil) == 12.5)
        #expect(TradeValue.fixed(12.5).resolve(market: 999) == 12.5)
    }

    @Test func storageRoundTrip() {
        for value: TradeValue in [.market, .percentOfMarket(90), .fixed(15)] {
            let restored = TradeValue.from(mode: value.mode, amount: value.amount)
            #expect(restored == value)
        }
        // Unknown / malformed modes degrade to market.
        #expect(TradeValue.from(mode: "bogus", amount: 5) == .market)
        #expect(TradeValue.from(mode: "market_pct", amount: nil) == .market)
    }

    @Test func labels() {
        #expect(TradeValue.market.label == "Market")
        #expect(TradeValue.percentOfMarket(90).label == "90% of market")
    }
}

// MARK: - Trade math

struct TradeMathTests {
    private func item(_ value: Double, _ dir: TradeDirection, qty: Int = 1) -> TradeItem {
        TradeItem(ref: CardRef(cardID: "c", variant: .normal), direction: dir, quantity: qty, valueEach: value)
    }

    @Test func valuesCashAndFairness() {
        // Give a $50 card, get a $30 card + $15 cash → you get 45, give 50.
        let trade = Trade(cashDelta: 15, items: [item(30, .incoming), item(50, .outgoing)])
        #expect(trade.valueIn == 30)
        #expect(trade.valueOut == 50)
        #expect(trade.youGet == 45)
        #expect(trade.youGive == 50)
        #expect(trade.netValue == -5)          // 30 - 50 + 15
        #expect(abs(trade.fairness - 0.9) < 0.0001)
    }

    @Test func cashPaidCountsAgainstYou() {
        // Get a $40 card, give a $20 card and pay $15 → net +5.
        let trade = Trade(cashDelta: -15, items: [item(40, .incoming), item(20, .outgoing)])
        #expect(trade.youGet == 40)
        #expect(trade.youGive == 35)
        #expect(trade.netValue == 5)
    }

    @Test func quantityScalesLineValue() {
        let trade = Trade(items: [item(10, .outgoing, qty: 3)])
        #expect(trade.valueOut == 30)
        #expect(trade.netValue == -30)
    }

    @Test func emptyTradeIsEven() {
        #expect(Trade().fairness == 1)
    }
}

// MARK: - Trading price resolver

struct TradingPriceTests {
    private func quote(_ source: PriceQuote.Source, _ variant: CardVariant, _ currency: String,
                       _ market: Double?, live: Bool) -> PriceQuote {
        PriceQuote(source: source, variant: variant, currency: currency, market: market,
                   low: nil, fetchedAt: .distantPast, isLive: live)
    }

    @Test func prefersExactVariantLiveTCGplayer() {
        let quotes = [
            quote(.tcgplayer, .holo, "USD", 8, live: false),
            quote(.tcgplayer, .holo, "USD", 10, live: true),
        ]
        let best = PriceStore.bestTradingPrice(from: quotes, variant: .holo)
        #expect(best?.amount == 10)
        #expect(best?.isLive == true)
        #expect(best?.currency == "USD")
    }

    @Test func fallsBackToNormalVariant() {
        let quotes = [quote(.tcgplayer, .normal, "USD", 5, live: true)]
        #expect(PriceStore.bestTradingPrice(from: quotes, variant: .reverse)?.amount == 5)
    }

    @Test func prefersUSDOverEUR() {
        let quotes = [
            quote(.tcgplayer, .normal, "USD", 5, live: true),
            quote(.cardmarket, .holo, "EUR", 20, live: true),
        ]
        #expect(PriceStore.bestTradingPrice(from: quotes, variant: .holo)?.currency == "USD")
    }

    @Test func cardmarketUsedWhenNoUSD() {
        let quotes = [quote(.cardmarket, .normal, "EUR", 7, live: true)]
        let best = PriceStore.bestTradingPrice(from: quotes, variant: .normal)
        #expect(best?.amount == 7)
        #expect(best?.currency == "EUR")
    }

    @Test func skipsUnrelatedVariantAndMissingMarket() {
        // A different specific variant is not an acceptable stand-in.
        #expect(PriceStore.bestTradingPrice(
            from: [quote(.tcgplayer, .firstEdition, "USD", 99, live: true)], variant: .holo) == nil)
        // No market at all → nil.
        #expect(PriceStore.bestTradingPrice(
            from: [quote(.tcgplayer, .holo, "USD", nil, live: true)], variant: .holo) == nil)
        #expect(PriceStore.bestTradingPrice(from: [], variant: .normal) == nil)
    }
}

// MARK: - Scanner core

@MainActor struct ScannerCoreTests {
    private func solidImage(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    @Test func centerCropIsCardAspectAndInsideFrame() throws {
        let img = solidImage(300, 400)
        let crop = try #require(SingleCardScanner.centerCardCrop(img))
        #expect(crop.width <= 300 && crop.height <= 400)
        let aspect = Double(crop.width) / Double(crop.height)
        #expect(abs(aspect - Double(SingleCardScanner.cardAspect)) < 0.02)
    }

    @Test func stabilizerRequiresStreakThenLocksOnce() {
        var stab = ScanStabilizer(minConfidence: 0.7, requiredStreak: 3)
        let good = [CardMatch(cardID: "base1-4", distance: 4)]  // confidence ~0.94
        #expect(stab.ingest(good) == nil)   // 1
        #expect(stab.ingest(good) == nil)   // 2
        #expect(stab.ingest(good) == "base1-4") // 3 → lock
        #expect(stab.ingest(good) == nil)   // already locked, no re-emit
        #expect(stab.locked == "base1-4")
    }

    @Test func lowConfidenceResetsStreak() {
        var stab = ScanStabilizer(minConfidence: 0.7, requiredStreak: 2)
        let good = [CardMatch(cardID: "x", distance: 4)]
        let weak = [CardMatch(cardID: "x", distance: 40)] // confidence ~0.375
        #expect(stab.ingest(good) == nil)
        #expect(stab.ingest(weak) == nil)   // resets
        #expect(stab.ingest(good) == nil)   // streak 1 again
        #expect(stab.ingest(good) == "x")   // streak 2 → lock
    }

    @Test func relocksWhenCardChanges() {
        var stab = ScanStabilizer(minConfidence: 0.7, requiredStreak: 1)
        #expect(stab.ingest([CardMatch(cardID: "a", distance: 2)]) == "a")
        #expect(stab.ingest([CardMatch(cardID: "a", distance: 2)]) == nil)
        #expect(stab.ingest([CardMatch(cardID: "b", distance: 2)]) == "b")
    }
}

// MARK: - Stores

@MainActor struct TradeStoreTests {
    @Test func savesReloadsAndComputesPL() async throws {
        let user = try UserDatabase.inMemory()
        let store = TradeStore(database: user)
        let ref = CardRef(cardID: "base1-4", variant: .holo)

        var trade = Trade(counterparty: "Alex", event: "City Show", cashDelta: 5)
        trade.items = [
            TradeItem(ref: ref, direction: .incoming, quantity: 1, valueEach: 20),
            TradeItem(ref: ref, direction: .outgoing, quantity: 1, valueEach: 30),
        ]
        #expect(store.save(trade))
        #expect(store.count == 1)
        #expect(store.totalNetValue == -5)               // 20 - 30 + 5
        #expect(store.recentEvents == ["City Show"])

        // Reloads from disk with items intact.
        let reloaded = TradeStore(database: user)
        await reloaded.load()
        #expect(reloaded.count == 1)
        let t = try #require(reloaded.trade(id: trade.id))
        #expect(t.counterparty == "Alex")
        #expect(t.incoming.count == 1)
        #expect(t.outgoing.first?.valueEach == 30)

        reloaded.delete(id: trade.id)
        #expect(reloaded.count == 0)
        let empty = TradeStore(database: user)
        await empty.load()
        #expect(empty.count == 0)
    }
}

@MainActor struct TradeListStoreTests {
    @Test func addToggleReload() async throws {
        let user = try UserDatabase.inMemory()
        let store = TradeListStore(database: user)
        let ref = CardRef(cardID: "base1-4", variant: .holo)

        #expect(store.toggle(ref) == true)
        #expect(store.isListed(ref))
        #expect(store.count == 1)

        // Edit the asking value.
        var listing = try #require(store.listing(for: ref))
        listing.value = .percentOfMarket(85)
        listing.quantity = 2
        #expect(store.save(listing))

        let reloaded = TradeListStore(database: user)
        await reloaded.load()
        let back = try #require(reloaded.listing(for: ref))
        #expect(back.value == .percentOfMarket(85))
        #expect(back.quantity == 2)

        #expect(store.toggle(ref) == false)
        #expect(!store.isListed(ref))
    }
}

@MainActor struct WishlistTargetTests {
    @Test func setTargetPersistsAndClearsOnUnwish() async throws {
        let user = try UserDatabase.inMemory()
        let store = WishlistStore(database: user)
        let ref = CardRef(cardID: "base1-4", variant: .holo)

        store.setTarget(ref, value: .percentOfMarket(90), priority: 2)
        #expect(store.isWished(ref))                 // setTarget wishes it
        #expect(store.target(for: ref) == .percentOfMarket(90))
        #expect(store.priority(for: ref) == 2)

        let reloaded = WishlistStore(database: user)
        await reloaded.load()
        #expect(reloaded.target(for: ref) == .percentOfMarket(90))
        #expect(reloaded.priority(for: ref) == 2)

        reloaded.set(ref, wished: false)
        #expect(reloaded.target(for: ref) == .market)  // cleared
        #expect(reloaded.priority(for: ref) == 0)
    }
}

// MARK: - Migration + backup

@MainActor struct TradeMigrationTests {
    @Test func v5SchemaExists() throws {
        let user = try UserDatabase.inMemory()
        try user.queue.read { db in
            for table in ["trade", "trade_item", "trade_list"] {
                #expect(try db.tableExists(table))
            }
            let wishlistCols = try db.columns(in: "wishlist").map(\.name)
            #expect(wishlistCols.contains("target_mode"))
            #expect(wishlistCols.contains("target_amount"))
            #expect(wishlistCols.contains("priority"))
        }
    }

    @Test func backupRoundTripsTradesListingsAndTargets() async throws {
        let user = try UserDatabase.inMemory()
        let trades = TradeStore(database: user)
        let list = TradeListStore(database: user)
        let wishlist = WishlistStore(database: user)
        let ref = CardRef(cardID: "base1-4", variant: .holo)

        var trade = Trade(counterparty: "Sam", event: "Nationals", cashDelta: -10)
        trade.items = [TradeItem(ref: ref, direction: .outgoing, quantity: 1, valueEach: 42)]
        trades.save(trade)
        list.save(TradeListing(ref: ref, condition: .lp, quantity: 3, value: .fixed(25)))
        wishlist.setTarget(CardRef(cardID: "swsh9-25", variant: .holo), value: .percentOfMarket(80), priority: 3)

        let data = try BackupService.export(user)
        try await user.queue.write { db in
            for t in ["trade_item", "trade", "trade_list", "wishlist"] { try db.execute(sql: "DELETE FROM \(t)") }
        }
        try BackupService.restore(data, into: user)

        let trades2 = TradeStore(database: user); await trades2.load()
        #expect(trades2.count == 1)
        #expect(trades2.trade(id: trade.id)?.cashDelta == -10)
        #expect(trades2.trade(id: trade.id)?.outgoing.first?.valueEach == 42)

        let list2 = TradeListStore(database: user); await list2.load()
        let listing = try #require(list2.listing(for: ref))
        #expect(listing.value == .fixed(25))
        #expect(listing.quantity == 3)

        let wishlist2 = WishlistStore(database: user); await wishlist2.load()
        #expect(wishlist2.target(for: CardRef(cardID: "swsh9-25", variant: .holo)) == .percentOfMarket(80))
        #expect(wishlist2.priority(for: CardRef(cardID: "swsh9-25", variant: .holo)) == 3)
    }
}
