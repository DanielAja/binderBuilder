//
//  GlassControls.swift
//  binderBuilder
//
//  iOS 26 Liquid Glass for floating controls (the navigation layer), with a
//  material fallback on earlier systems so the app still ships to iOS 18+.
//  Plus a tiny Haptics helper so feedback is consistent across the app.
//

import SwiftUI
import UIKit

extension View {
    /// Liquid Glass capsule for floating controls on iOS 26+, `.ultraThinMaterial`
    /// below. Use only for controls that float above content (HIG: glass belongs
    /// on the navigation layer, never on lists/cards).
    @ViewBuilder func floatingGlass() -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// Adopts the tab-bar minimize-on-scroll behavior on iOS 26+ (no-op below).
    @ViewBuilder func minimizingTabBar() -> some View {
        if #available(iOS 26, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}

/// Consistent haptic feedback. Cheap to call; generators are created on demand.
@MainActor
enum Haptics {
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}
