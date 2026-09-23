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
                    // Full-alpha secondary at 1.5 pt: the dashes are a
                    // non-text element, so they need 3:1 against the tray.
                    .strokeBorder(Color.secondary,
                                  style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
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

    /// The wobble toggles between the two extremes so the cell leans about
    /// zero; animating `active` itself only swung from upright to one side.
    @State private var tick = false

    func body(content: Content) -> some View {
        content
            // Inactive is always upright, so a stale `tick` leaves no lean.
            .rotationEffect(.degrees(active ? (tick ? 1.2 : -1.2) : 0))
            .onChange(of: active, initial: true) { _, on in
                if on {
                    tick = phase.isMultiple(of: 2)
                    withAnimation(.easeInOut(duration: 0.14)
                        .repeatForever(autoreverses: true)
                        .delay(Double(phase % 3) * 0.045)) {
                        tick.toggle()
                    }
                } else {
                    withAnimation(.default) { tick = false }
                }
            }
    }
}
