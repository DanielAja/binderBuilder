//
//  SingleCardScanner.swift
//  binderBuilder
//
//  The fast single-card path (vs BinderScanPipeline's 3×3 page): center-crop
//  the frame under the reticle to card aspect, dHash it, and shortlist matches.
//  `ScanStabilizer` debounces a live stream so we only "lock" a card once it
//  tops the matches for a few consecutive frames — no flicker while panning.
//
//  Reticle/crop alignment: the preview layer fills the screen with
//  `.resizeAspectFill`, so parts of the 16:9 camera frame are always
//  off-screen — the sides on a 19.5:9 phone, the top and bottom on an iPad. In
//  frame-pixel terms "what the user sees" therefore differs per device, so
//  a fixed crop and a fixed reticle can't agree everywhere. `cropRect`
//  therefore sizes the analyzed region against the *visible* part of the frame
//  and `visibleCropRect` projects it back to screen points, so FastScanView can
//  draw a reticle that frames exactly the pixels we hash on every aspect ratio.
//

import CoreGraphics
import Foundation

nonisolated enum SingleCardScanner {
    /// A trading card's width:height (2.5" × 3.5").
    static let cardAspect: CGFloat = 2.5 / 3.5
    /// Fractions of the *visible* frame the reticle fills when there's a live
    /// preview: wide enough to aim with, short enough to clear the top bar and
    /// the result card on a 375 pt screen.
    private static let previewWidthFill: CGFloat = 0.72
    private static let previewHeightFill: CGFloat = 0.56
    /// The chosen-photo path has no reticle, so it crops as much as it can.
    private static let stillWidthFill: CGFloat = 0.95

    /// The analyzed region in frame-pixel coords: a centered card-aspect
    /// rectangle sized against the part of the frame the aspect-fill preview
    /// actually shows, so it lands where the reticle is drawn. A `.zero`
    /// `viewSize` (no live preview — the chosen-photo path) instead crops
    /// `maxHeightFraction` of the whole frame.
    static func cropRect(
        frameSize: CGSize, viewSize: CGSize = .zero, maxHeightFraction: CGFloat = 0.82
    ) -> CGRect {
        guard frameSize.width > 0, frameSize.height > 0 else { return .zero }
        let widthLimit: CGFloat, heightLimit: CGFloat
        if viewSize.width > 0, viewSize.height > 0 {
            let visible = visibleFrameSize(frameSize: frameSize, viewSize: viewSize)
            widthLimit = visible.width * previewWidthFill
            heightLimit = min(frameSize.height * maxHeightFraction,
                              visible.height * previewHeightFill)
        } else {
            widthLimit = frameSize.width * stillWidthFill
            heightLimit = frameSize.height * maxHeightFraction
        }
        var cropH = heightLimit
        var cropW = cropH * cardAspect
        if cropW > widthLimit { cropW = widthLimit; cropH = cropW / cardAspect }
        return CGRect(x: (frameSize.width - cropW) / 2, y: (frameSize.height - cropH) / 2,
                      width: cropW, height: cropH)
    }

    /// Where the analyzed crop lands on screen, in view points, once the
    /// preview aspect-fills `viewSize`. This is the reticle.
    static func visibleCropRect(
        frameSize: CGSize, viewSize: CGSize, maxHeightFraction: CGFloat = 0.82
    ) -> CGRect {
        let crop = cropRect(frameSize: frameSize, viewSize: viewSize,
                            maxHeightFraction: maxHeightFraction)
        return project(crop, frameSize: frameSize, viewSize: viewSize)
    }

    /// Maps a frame-pixel rect into view points under `.resizeAspectFill`:
    /// uniform scale to cover, centered, so the overflowing axis is clipped.
    static func project(_ rect: CGRect, frameSize: CGSize, viewSize: CGSize) -> CGRect {
        guard frameSize.width > 0, frameSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let scale = max(viewSize.width / frameSize.width, viewSize.height / frameSize.height)
        let originX = (viewSize.width - frameSize.width * scale) / 2
        let originY = (viewSize.height - frameSize.height * scale) / 2
        return CGRect(x: originX + rect.minX * scale, y: originY + rect.minY * scale,
                      width: rect.width * scale, height: rect.height * scale)
    }

    /// The part of the frame the aspect-fill preview shows, in frame pixels.
    private static func visibleFrameSize(frameSize: CGSize, viewSize: CGSize) -> CGSize {
        guard viewSize.width > 0, viewSize.height > 0 else { return frameSize }
        let scale = max(viewSize.width / frameSize.width, viewSize.height / frameSize.height)
        return CGSize(width: min(frameSize.width, viewSize.width / scale),
                      height: min(frameSize.height, viewSize.height / scale))
    }

    /// Crops the frame to the analyzed region (see `cropRect`).
    static func centerCardCrop(
        _ image: CGImage, viewSize: CGSize = .zero, maxHeightFraction: CGFloat = 0.82
    ) -> CGImage? {
        let frameSize = CGSize(width: image.width, height: image.height)
        let rect = cropRect(frameSize: frameSize, viewSize: viewSize,
                            maxHeightFraction: maxHeightFraction)
        guard !rect.isEmpty else { return nil }
        return image.cropping(to: rect.integral)
    }

    /// Best matches for the card under the reticle in a full frame. Safe to
    /// call off the main actor — the matcher's index is immutable.
    static func matches(
        in image: CGImage, viewSize: CGSize = .zero,
        using matcher: CardHashMatcher, limit: Int = 5
    ) -> [CardMatch] {
        guard let crop = centerCardCrop(image, viewSize: viewSize) else { return [] }
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
