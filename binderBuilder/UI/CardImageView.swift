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

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .saturation(owned ? 1 : 0)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(white: 0.16))
                    .overlay(ProgressView().tint(.white.opacity(0.5)))
                    .aspectRatio(63.0 / 88.0, contentMode: .fit)
            }
        }
        .task(id: cardID) {
            image = nil
            if let cg = try? await imageCache.image(
                for: cardID, imageBase: imageBase, quality: quality, pinned: false
            ) {
                image = UIImage(cgImage: cg)
            }
        }
    }
}
