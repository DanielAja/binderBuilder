//
//  CardImageView.swift
//  binderBuilder
//
//  Async card art for the 2D UI, sourced through the shared ImageCache (same
//  CGImages the 3D layer uses). Shows a rounded placeholder while loading and
//  a card-back for cards with no image. Optionally desaturates unowned cards
//  to match the binder's color/grayscale convention.
//

import SwiftUI

struct CardImageView: View {
    let cardID: String
    let imageBase: String?
    var quality: ImageQuality = .low
    var owned: Bool = true
    let imageCache: ImageCache

    @State private var image: UIImage?

    /// Everything the fetch depends on. Keying `.task` on the card id alone
    /// left the old art on screen when only the image base or the quality
    /// changed (a reused row rebound to a different printing), which the call
    /// sites worked around with `.id(summary?.imageBase)`.
    private struct LoadKey: Hashable {
        let cardID: String
        let imageBase: String?
        let quality: ImageQuality
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .saturation(owned ? 1 : 0)
            } else {
                // `.secondarySystemFill` reads as a quiet tile in both
                // appearances; a fixed dark gray flashed near-black in light
                // mode. The shimmer only runs while the fetch is in flight —
                // a failed fetch lands on the card back below, so nothing
                // shimmers forever.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(.secondarySystemFill))
                    .aspectRatio(63.0 / 88.0, contentMode: .fit)
                    .shimmering()
            }
        }
        .task(id: LoadKey(cardID: cardID, imageBase: imageBase, quality: quality)) {
            image = nil
            do {
                image = UIImage(cgImage: try await imageCache.image(
                    for: cardID, imageBase: imageBase, quality: quality, pinned: false))
            } catch {
                // A cancelled task is a re-key, not a failure: the new task
                // has already reset `image`, so leave it alone.
                guard !Task.isCancelled else { return }
                image = UIImage(cgImage: PlaceholderArt.cardBack)
            }
        }
    }
}
