//
//  LiveScanModel.swift
//  binderBuilder
//
//  Drives the fast scanner: turns a stream of camera frames (or a single
//  chosen photo) into a "locked" card with a live trading price, and provides
//  one-tap quick-add to the collection / for-trade list / wishlist. A sticky
//  destination + default condition keep bulk scanning to zero extra taps.
//

import CoreGraphics
import Foundation
import Observation
import UIKit

@MainActor @Observable final class LiveScanModel {
    enum Destination: String, CaseIterable, Sendable {
        case collection = "Collection"
        case forTrade = "For Trade"
    }

    /// The currently identified card and its resolved price.
    struct Locked: Equatable {
        var card: CardSummary
        var variant: CardVariant
        var confidence: Double
        var price: TradingPrice?
        var priceLoading: Bool
        var added: Bool
    }

    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private var matcher: CardHashMatcher?
    @ObservationIgnored private var stabilizer = ScanStabilizer()
    /// Monotonic token so a slow price/detail lookup can't overwrite a newer lock.
    @ObservationIgnored private var lookupToken = 0
    /// One match at a time: matching is now off-main, and dropping frames while
    /// one is in flight keeps the stabilizer's streak in capture order.
    @ObservationIgnored private var isMatching = false
    /// Size of the on-screen preview, set by the view. The analyzed crop is
    /// sized against it so it matches what the reticle shows on this device.
    @ObservationIgnored var previewSize: CGSize = .zero

    private(set) var isReady = false
    /// Pixel size of the frames we're analyzing (the reticle is derived from it).
    private(set) var frameSize = CameraScanner.frameSize
    var locked: Locked?
    /// Sticky quick-add target + default condition for a bulk run.
    var destination: Destination = .collection
    var defaultCondition: CardCondition = .nm
    private(set) var addedCount = 0
    private(set) var addedValue: Double = 0
    var lastActionText: String?
    /// Cards added during this run, waiting to be turned over in the reveal.
    /// One entry per add, so scanning the same card twice reveals it twice.
    private(set) var revealQueue: [RevealItem] = []

    var hasRevealQueue: Bool { !revealQueue.isEmpty }

    init(env: AppEnvironment) { self.env = env }

    /// Loads the hash index once. Ready only if the catalog produced entries.
    func prepare() async {
        if matcher == nil, let catalog = env.catalog {
            matcher = await CardHashMatcher.load(from: catalog)
        }
        isReady = !(matcher?.isEmpty ?? true)
    }

    // MARK: - Frame ingestion

    /// A live camera frame (already throttled by the capture layer). Locks a
    /// card only after it's topped the shortlist for a few consecutive frames.
    func ingestFrame(_ frame: CGImage) {
        guard let matcher, !isMatching else { return }
        isMatching = true
        let size = CGSize(width: frame.width, height: frame.height)
        if size != frameSize { frameSize = size }
        let viewSize = previewSize
        Task {
            let matches = await Self.matches(in: frame, viewSize: viewSize, using: matcher)
            isMatching = false
            guard let newID = stabilizer.ingest(matches) else { return }
            await lock(cardID: newID, confidence: matches.first?.confidence ?? 0)
        }
    }

    /// The crop + dHash + full-index Hamming scan. `nonisolated async` puts it
    /// on the concurrent executor, so only the shortlist comes back to main.
    private nonisolated static func matches(
        in frame: CGImage, viewSize: CGSize, using matcher: CardHashMatcher
    ) async -> [CardMatch] {
        SingleCardScanner.matches(in: frame, viewSize: viewSize, using: matcher)
    }

    /// One-shot identification from a chosen still (the Simulator / no-camera
    /// path), which bypasses the multi-frame streak requirement.
    func scanStill(_ frame: CGImage) async {
        guard let matcher else { return }
        // A chosen photo isn't the preview, so the crop uses frame limits only.
        let matches = await Self.matches(in: frame, viewSize: .zero, using: matcher)
        guard let top = matches.first, top.confidence >= 0.5 else {
            lastActionText = "No card recognized — try a clearer photo."
            clearActionSoon()
            return
        }
        stabilizer.reset()
        await lock(cardID: top.cardID, confidence: top.confidence)
    }

    private func lock(cardID: String, confidence: Double) async {
        lookupToken += 1
        let token = lookupToken
        guard let detail = try? await env.catalog?.card(id: cardID), token == lookupToken else { return }
        let variant = Self.primaryVariant(of: detail.summary)
        Haptics.impact(.medium)
        locked = Locked(card: detail.summary, variant: variant, confidence: confidence,
                        price: nil, priceLoading: true, added: false)
        await resolvePrice(for: cardID, variant: variant, token: token, refreshLive: true)
    }

    /// Fills the price chip: cached/bundled first (instant), then a live refresh.
    private func resolvePrice(
        for cardID: String, variant: CardVariant, token: Int, refreshLive: Bool
    ) async {
        let ref = CardRef(cardID: cardID, variant: variant)
        let cached = await env.prices.tradingPrice(for: ref)
        guard token == lookupToken, locked?.card.id == cardID else { return }
        locked?.price = cached
        locked?.priceLoading = false
        hapticForPrice(cached?.amount)

        guard refreshLive else { return }
        guard let card = locked?.card, card.id == cardID else { return }
        await env.prices.refreshIfStale(card: card)
        let fresh = await env.prices.tradingPrice(for: ref)
        guard token == lookupToken, locked?.card.id == cardID else { return }
        locked?.price = fresh
    }

    /// Re-price when the user disambiguates the variant on the locked card.
    func chooseVariant(_ variant: CardVariant) {
        guard var current = locked, current.variant != variant else { return }
        current.variant = variant
        current.priceLoading = true
        current.added = false
        locked = current
        lookupToken += 1
        let token = lookupToken
        Task { await resolvePrice(for: current.card.id, variant: variant, token: token, refreshLive: false) }
    }

    // MARK: - Quick add

    /// Adds the locked card to the sticky destination. Idempotent per lock.
    func quickAdd() {
        guard var current = locked, !current.added else { return }
        let ref = CardRef(cardID: current.card.id, variant: current.variant)
        switch destination {
        case .collection:
            env.collection.addCopy(ref, condition: defaultCondition)
        case .forTrade:
            env.tradeList.save(TradeListing(ref: ref, condition: defaultCondition))
        }
        current.added = true
        locked = current
        addedCount += 1
        addedValue += current.price?.amount ?? 0
        revealQueue.append(RevealItem(
            cardID: current.card.id,
            name: current.card.name,
            imageBase: current.card.imageBase,
            price: current.price?.amount))
        Haptics.success()
        announce("Added \(current.card.name) to \(destination.rawValue)")
    }

    /// Drops the queue once the reveal has played (or been skipped).
    func clearRevealQueue() { revealQueue.removeAll() }

    func addToWishlist() {
        guard let current = locked else { return }
        let ref = CardRef(cardID: current.card.id, variant: current.variant)
        let wished = env.wishlist.toggle(ref)
        Haptics.selection()
        announce(wished ? "Added \(current.card.name) to wishlist" : "Removed from wishlist")
    }

    func dismissLock() { stabilizer.reset(); locked = nil }

    // MARK: - Helpers

    /// Loads a demo lock for Simulator screenshot verification (-fastScanDemo).
    func injectDemo(cardID: String) async {
        await lock(cardID: cardID, confidence: 0.94)
    }

    private func announce(_ text: String) {
        lastActionText = text
        clearActionSoon()
    }

    private func clearActionSoon() {
        Task {
            try? await Task.sleep(for: .seconds(2))
            lastActionText = nil
        }
    }

    /// Value-tiered feedback so a chase card can be felt without looking.
    private func hapticForPrice(_ amount: Double?) {
        guard let amount else { return }
        if amount >= 25 {
            Haptics.impact(.heavy)
            Task { try? await Task.sleep(for: .milliseconds(90)); Haptics.impact(.rigid) }
        } else if amount >= 5 {
            Haptics.impact(.medium)
        }
    }

    nonisolated static func primaryVariant(of card: CardSummary) -> CardVariant {
        let preferred: [CardVariant] = [.holo, .normal, .reverse, .firstEdition]
        return preferred.first { card.availableVariants.contains($0) } ?? .normal
    }
}
