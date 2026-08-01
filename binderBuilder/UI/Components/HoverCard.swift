//
//  HoverCard.swift
//  binderBuilder
//
//  `hoverCard(intensity:)` — a gentle floating-in-space feel for hero card
//  art: a slow, organic sway across both axes driven by `TimelineView`, a
//  soft vertical bob, and a shadow that slides opposite the tilt to sell the
//  depth. While the user drags on the card, the idle sway pauses and the
//  card tilts straight at the finger instead, springing back on release.
//
//  Reduce Motion drops the idle oscillation and bob entirely — direct
//  manipulation from a drag is exempt, so touch-tilt still works — and falls
//  back to a static shadow.
//
//  The sway math lives in `HoverCardMath.angles(at:intensity:)`, a pure,
//  nonisolated function kept free of view state so it's directly testable.
//

import SwiftUI

extension View {
    /// Wraps this view in a slow 3D "hover": idle sway plus a touch tilt.
    /// - Parameter intensity: scales every rotation/bob amplitude; 0 disables
    ///   the idle motion outright (touch-tilt still responds).
    func hoverCard(intensity: Double = 1) -> some View {
        modifier(HoverCardModifier(intensity: intensity))
    }
}

/// Pure sway math, factored out of the view so it can be unit tested without
/// standing up a `TimelineView`.
enum HoverCardMath {
    /// Idle-sway amplitude caps, before `intensity` scales them down.
    static let maxTiltX = 4.0    // degrees
    static let maxTiltY = 6.0    // degrees
    static let maxBob: CGFloat = 3  // points

    /// Periods, in seconds, of the two tilt axes and the bob (2π × the
    /// sine's time divisor below).
    static let periodX = 2 * Double.pi * 3.4
    static let periodY = 2 * Double.pi * 2.6
    static let periodBob = 2 * Double.pi * 3.0

    /// Phase offsets between the axes/bob so the sway reads as organic
    /// drift rather than a mechanically synced wobble.
    private static let yPhase = Double.pi / 5
    private static let bobPhase = Double.pi / 3

    /// The idle-sway rotation (around x and y) and vertical bob at `time`
    /// seconds into the timeline, scaled by `intensity`. `intensity == 0`
    /// yields exactly zero for all three.
    static func angles(at time: Double, intensity: Double) -> (x: Angle, y: Angle, bob: CGFloat) {
        guard intensity != 0 else { return (.zero, .zero, 0) }
        let x = Angle.degrees(sin(time / 3.4) * maxTiltX * intensity)
        let y = Angle.degrees(sin(time / 2.6 + yPhase) * maxTiltY * intensity)
        let bob = CGFloat(sin(time / 3.0 + bobPhase)) * maxBob * intensity
        return (x, y, bob)
    }
}

private struct HoverCardModifier: ViewModifier {
    let intensity: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Fixed at first render so `TimelineView`'s dates map to a stable
    /// "seconds since this card appeared" clock.
    @State private var startDate = Date()
    @State private var size: CGSize = .zero
    @State private var dragTilt: (x: Angle, y: Angle)?

    private static let maxDragTilt = 10.0
    private static let perspective = 0.35
    private static let dragSpring = Animation.spring(response: 0.35, dampingFraction: 0.7)

    func body(content: Content) -> some View {
        if reduceMotion {
            // No oscillation/bob; touch-tilt (direct manipulation) and a
            // static shadow are all that remain.
            content
                .rotation3DEffect(dragTilt?.x ?? .zero, axis: (1, 0, 0), perspective: Self.perspective)
                .rotation3DEffect(dragTilt?.y ?? .zero, axis: (0, 1, 0), perspective: Self.perspective)
                .shadow(color: .black.opacity(0.22), radius: 12, x: 0, y: 8)
                .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
                .gesture(dragGesture)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let t = timeline.date.timeIntervalSince(startDate)
                let sway = HoverCardMath.angles(at: t, intensity: intensity)
                let x = dragTilt?.x ?? sway.x
                let y = dragTilt?.y ?? sway.y
                let bob = dragTilt == nil ? sway.bob : 0

                content
                    .rotation3DEffect(x, axis: (1, 0, 0), perspective: Self.perspective)
                    .rotation3DEffect(y, axis: (0, 1, 0), perspective: Self.perspective)
                    .offset(y: bob)
                    .shadow(
                        color: .black.opacity(0.26),
                        radius: 14,
                        // Shadow drifts opposite the tilt, like the card is
                        // casting light past itself as it leans.
                        x: -CGFloat(y.degrees) * 0.7,
                        y: 8 + CGFloat(x.degrees) * 0.7
                    )
            }
            .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
            .gesture(dragGesture)
            .drawingGroup()
        }
    }

    /// Maps the drag location within the card to a tilt toward the finger,
    /// clamped to `maxDragTilt`, springing back to the idle sway on release.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard size.width > 0, size.height > 0 else { return }
                let nx = ((value.location.x / size.width) - 0.5) * 2
                let ny = ((value.location.y / size.height) - 0.5) * 2
                let clampedX = min(max(nx, -1), 1)
                let clampedY = min(max(ny, -1), 1)
                dragTilt = (
                    x: .degrees(-clampedY * Self.maxDragTilt),
                    y: .degrees(clampedX * Self.maxDragTilt)
                )
            }
            .onEnded { _ in
                withAnimation(Self.dragSpring) { dragTilt = nil }
            }
    }
}
