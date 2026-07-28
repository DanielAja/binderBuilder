//
//  SingleCardScanner.swift
//  binderBuilder
//
//  The fast single-card path (vs BinderScanPipeline's 3×3 page): center-crop
//  the frame under the reticle to card aspect, dHash it, and shortlist matches.
//  `ScanStabilizer` debounces a live stream so we only "lock" a card once it
//  tops the matches for a few consecutive frames — no flicker while panning.
//

import CoreGraphics
import Foundation

@MainActor
enum SingleCardScanner {
    /// A trading card's width:height (2.5" × 3.5").
    nonisolated static let cardAspect: CGFloat = 2.5 / 3.5

    /// Crops a centered card-aspect rectangle covering `heightFraction` of the
    /// frame height (so a card held under the reticle fills the crop).
    nonisolated static func centerCardCrop(
        _ image: CGImage, heightFraction: CGFloat = 0.82
    ) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard w > 0, h > 0 else { return nil }
        var cropH = h * heightFraction
        var cropW = cropH * cardAspect
        if cropW > w * 0.95 { cropW = w * 0.95; cropH = cropW / cardAspect }
        let rect = CGRect(x: (w - cropW) / 2, y: (h - cropH) / 2, width: cropW, height: cropH)
            .integral
        return image.cropping(to: rect)
    }

    /// Best matches for the card under the reticle in a full frame.
    static func matches(
        in image: CGImage, using matcher: CardHashMatcher, limit: Int = 5
    ) -> [CardMatch] {
        guard let crop = centerCardCrop(image) else { return [] }
        return matcher.match(PerceptualHash.dHash(crop), limit: limit)
    }
}

/// Temporal debounce over a live match stream. Emits a card id only when the
/// same card has topped the shortlist for `requiredStreak` frames above the
/// confidence floor, and won't re-emit the same lock until it changes.
struct ScanStabilizer: Sendable {
    var minConfidence: Double
    var requiredStreak: Int

    private var currentID: String?
    private var streak: Int = 0
    private(set) var locked: String?

    init(minConfidence: Double = 0.70, requiredStreak: Int = 3) {
        self.minConfidence = minConfidence
        self.requiredStreak = requiredStreak
    }

    /// Feeds one frame's matches. Returns the newly-locked card id, or nil.
    mutating func ingest(_ matches: [CardMatch]) -> String? {
        guard let top = matches.first, top.confidence >= minConfidence else {
            currentID = nil; streak = 0
            return nil
        }
        if top.cardID == currentID {
            streak += 1
        } else {
            currentID = top.cardID
            streak = 1
        }
        if streak >= requiredStreak, locked != top.cardID {
            locked = top.cardID
            return top.cardID
        }
        return nil
    }

    mutating func reset() {
        currentID = nil
        streak = 0
        locked = nil
    }
}
