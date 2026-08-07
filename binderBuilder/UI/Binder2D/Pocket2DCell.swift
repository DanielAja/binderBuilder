//
//  Pocket2DCell.swift
//  binderBuilder
//
//  One pocket in the 2D binder editor: async card art through the shared
//  ImageCache (grayscale when unowned, matching the 3D convention), or a
//  dashed empty pocket with a gently pulsing plus.
//

import SwiftUI

struct Pocket2DCell: View {
    let content: SlotContent?
    let imageCache: ImageCache
    /// Arrange mode's Home-Screen-style wobble (occupied pockets only).
    var jiggle = false
    /// Staggers the wobble so neighbors don't move in lockstep.
    var jigglePhase = 0
    /// Move-selection highlight (the source pocket awaiting its target).
    var highlighted = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cardAspect: CGFloat = 63.0 / 88.0

    var body: some View {
        ZStack {
            if let content {
                CardImageView(
                    cardID: content.card.id,
                    imageBase: content.card.imageBase,
                    owned: content.owned,
                    imageCache: imageCache)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.5),
                                  style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .overlay {
                        Image(systemName: "plus")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.secondary)
                            .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                    }
            }
        }
        .aspectRatio(Self.cardAspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .overlay {
            if highlighted {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
            }
        }
        .scaleEffect(highlighted ? 1.05 : 1)
        .modifier(JiggleEffect(active: jiggle && content != nil && !reduceMotion,
                               phase: jigglePhase))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: highlighted)
    }
}

/// The Home-Screen-edit wobble: a small repeating rotation, phase-offset per
/// cell so a page of cards shimmers rather than marching in step.
private struct JiggleEffect: ViewModifier {
    let active: Bool
    let phase: Int

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(active ? (phase.isMultiple(of: 2) ? 1.2 : -1.2) : 0))
            .animation(
                active
                    ? .easeInOut(duration: 0.14)
                        .repeatForever(autoreverses: true)
                        .delay(Double(phase % 3) * 0.045)
                    : .default,
                value: active)
    }
}
