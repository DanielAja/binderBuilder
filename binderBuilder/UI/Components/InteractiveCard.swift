//
//  InteractiveCard.swift
//  binderBuilder
//
//  One treatment for every place the 2D UI shows a SINGLE card large enough to
//  be the subject of the screen: `interactiveCard(foil:intensity:)`. It is a
//  composition, not a new engine — three pieces that already exist, wired to
//  the same feedback language the 3D floating card uses:
//
//    1. Motion  — `hoverCard()`'s idle sway plus tilt-toward-the-finger.
//    2. Haptics — a selection tick when the finger lands, a soft tick every
//       ~5 degrees the tilt travels, a rigid thump on release. That is the 3D
//       card's grab / 0.32 rad tick / release-thump language scaled down to a
//       flat card that only tilts +-10 degrees.
//    3. Foil    — a device-tilt sheen (`tiltShimmer`) whose loudness, tint, and
//       whether it also gets a slow periodic `glintSweep` pass all come from
//       the printing's `FoilTier`, collapsed into three UI bands.
//
//  Accents only: the sheen and the sweep are deliberately quiet so the art
//  underneath stays readable, and the sweep fires roughly every 5 seconds
//  rather than looping continuously.
//
//  Reduce Motion: the sway and the periodic sweep both stop and the sheen goes
//  static (all of that is inherited from `hoverCard`/`tiltShimmer`), but the
//  haptics are UNCHANGED — the tick language is direct-manipulation feedback,
//  not decoration, so it survives.
//
//  NOT for grids and lists. Each of these carries a 30 Hz timeline and a
//  drawing group; a scrolling wall of them would be a frame-budget disaster.
//  Grid thumbnails keep the plain `CardImageView`.
//

import Foundation
import QuartzCore
import SwiftUI
import UIKit

// MARK: - Foil bands

/// How loud a card's foil reads in the flat UI. `FoilTier` has nine shader
/// branches; at thumbnail-to-hero size on a 2D image only three treatments are
/// distinguishable, so every tier collapses into one of these.
nonisolated enum FoilBand: String, CaseIterable, Sendable {
    /// No foil at all — plain art, no overlay, no subscription.
    case flat
    /// A restrained sheen. Enough to catch the light, no sweep.
    case subtle
    /// Full-strength sheen plus the periodic glint pass.
    case bright
    /// Like `bright`, warmed to gold. Reserved for the gold tiers.
    case gold

    /// Total by construction — no `default`, so a new `FoilTier` case is a
    /// compile error here rather than a silently flat card.
    static func band(for tier: FoilTier) -> FoilBand {
        switch tier {
        case .none:
            return .flat
        // Foils that are partial (art window only, or everything BUT the art
        // window) or deliberately restrained by design.
        case .holoArt, .reverseInverse, .illustrationRare:
            return .subtle
        // Full-face treatments: etched relief, dense glitter, rainbow bands.
        case .fullArtEtched, .specialIllustrationRare, .secretRainbow:
            return .bright
        case .goldHyper, .megaHyperGold:
            return .gold
        }
    }

    /// Sheen opacity multiplier handed to `tiltShimmer`.
    var sheen: Double {
        switch self {
        case .flat: return 0
        case .subtle: return 0.55
        case .bright: return 1
        case .gold: return 1.1
        }
    }

    /// Whether this band also gets the slow periodic glint pass.
    var sweeps: Bool { self == .bright || self == .gold }

    /// Highlight color. Warm gold only for the gold tiers; a tinted sheen on
    /// anything else would fight the art's own colors.
    var tint: Color {
        self == .gold
            ? Color(.sRGB, red: 1.0, green: 0.86, blue: 0.55, opacity: 1)
            : .white
    }

    /// Seconds between glint passes. Long enough that the sweep reads as the
    /// card catching a passing light, not as an animation loop.
    static let sweepPeriod: Double = 5
    /// Seconds one pass takes to cross the card.
    static let sweepDuration: Double = 0.7
}

// MARK: - Tick math

/// Decides when the touch-tilt has traveled far enough to deserve a haptic
/// tick. Pure and nonisolated: no view state, no generators, so the whole
/// crossing/rate-limiting policy is unit testable.
///
/// Mirrors `CardInteractionController`'s accumulate-and-fire scheme (soft tick
/// every ~0.32 rad of 3D rotation), with degrees instead of radians because the
/// flat card's tilt is bounded at +-10 degrees per axis.
nonisolated struct TiltTickTracker {
    /// Tilt distance, in degrees, between ticks.
    static let stepDegrees: Double = 5
    /// Floor on the gap between two ticks. A fast flick across the card can
    /// cross several steps within one frame; without this the generator gets a
    /// burst that reads as a buzz rather than a texture.
    static let minInterval: Double = 0.045

    /// 0 disables ticking outright (matches `interactiveCard`'s intensity 0).
    let intensity: Double

    private var accumulated: Double = 0
    private var last: (x: Double, y: Double)?
    private var lastTick: Double = -.greatestFiniteMagnitude

    init(intensity: Double = 1) {
        self.intensity = intensity
    }

    /// Seeds the path at the touch-down tilt. No tick of its own — the
    /// touch-down gets the selection haptic instead.
    mutating func begin(x: Double, y: Double) {
        last = (x, y)
        accumulated = 0
        lastTick = -.greatestFiniteMagnitude
    }

    /// Feeds one tilt sample. Returns true when a tick should play.
    ///
    /// Distance is the straight-line move through the (pitch, yaw) plane, the
    /// 2D analogue of the 3D controller's axis-angle magnitude, so a diagonal
    /// drag ticks at the same rate as a straight one of the same length.
    mutating func update(x: Double, y: Double, time: Double) -> Bool {
        guard let previous = last else {
            begin(x: x, y: y)
            return false
        }
        last = (x, y)
        guard intensity > 0 else { return false }

        accumulated += hypot(x - previous.x, y - previous.y)
        guard accumulated >= Self.stepDegrees else { return false }

        guard time - lastTick >= Self.minInterval else {
            // Hold the crossing so it fires the moment the limiter opens, but
            // cap it so a long swallowed stretch can't queue a double tick.
            accumulated = min(accumulated, Self.stepDegrees * 2)
            return false
        }
        accumulated = 0
        lastTick = time
        return true
    }

    /// Replays a whole tilt path and counts the ticks it would produce. The
    /// first sample seeds the path (as `begin` does); the rest are updates.
    static func tickCount(path: [(x: Double, y: Double, time: Double)], intensity: Double = 1) -> Int {
        guard let first = path.first else { return 0 }
        var tracker = TiltTickTracker(intensity: intensity)
        tracker.begin(x: first.x, y: first.y)
        var ticks = 0
        for sample in path.dropFirst() {
            if tracker.update(x: sample.x, y: sample.y, time: sample.time) { ticks += 1 }
        }
        return ticks
    }
}

// MARK: - Haptic engine

/// Owns the prepared generators and the tick tracker across one drag. A class
/// because the tracker has to survive between gesture callbacks, and because
/// `UIImpactFeedbackGenerator` wants to be kept alive and re-`prepare()`d
/// rather than rebuilt per tick.
private final class TiltHapticEngine {
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private var tracker = TiltTickTracker(intensity: 0)
    private var intensity: Double = 0

    /// Finger down: "picked it up".
    func began(x: Double, y: Double, intensity: Double) {
        self.intensity = intensity
        tracker = TiltTickTracker(intensity: intensity)
        tracker.begin(x: x, y: y)
        guard intensity > 0 else { return }
        soft.prepare()
        rigid.prepare()
        Haptics.selection()
    }

    /// Finger moved: a soft tick per 5 degrees traveled.
    func changed(x: Double, y: Double) {
        guard tracker.update(x: x, y: y, time: CACurrentMediaTime()) else { return }
        soft.impactOccurred(intensity: 0.4)
        soft.prepare()
    }

    /// Finger up: the card springs back with a light rigid thump.
    func ended() {
        guard intensity > 0 else { return }
        rigid.impactOccurred(intensity: 0.5)
    }
}

// MARK: - Modifier

extension View {
    /// The unified single-card treatment: 3D touch response, haptic texture,
    /// and a foil sheen keyed to the printing.
    ///
    /// - Parameters:
    ///   - foil: the printing's tier; `.none` means no sheen and no sweep.
    ///   - intensity: overall restraint dial. 1 for a hero, ~0.6 for a sheet
    ///     header, ~0.5 for a result thumbnail. 0 stops the idle motion AND all
    ///     haptics (touch-tilt still tracks the finger).
    func interactiveCard(foil: FoilTier = .none, intensity: Double = 1) -> some View {
        modifier(InteractiveCardModifier(band: FoilBand.band(for: foil), intensity: intensity))
    }

    /// Convenience: resolves the tier from a raw catalog rarity string plus the
    /// printing being shown, through the same normalization the 3D cards use.
    func interactiveCard(rarity: String?, variant: CardVariant, intensity: Double = 1) -> some View {
        interactiveCard(foil: FoilTier.resolve(rarity: rarity, variant: variant), intensity: intensity)
    }

    /// Convenience for the UI layer's card model. The summary is optional
    /// because most sheets render before their catalog lookup lands — a nil
    /// summary is simply a flat card until it arrives.
    func interactiveCard(card: CardSummary?, variant: CardVariant, intensity: Double = 1) -> some View {
        interactiveCard(rarity: card?.rarity, variant: variant, intensity: intensity)
    }
}

private struct InteractiveCardModifier: ViewModifier {
    let band: FoilBand
    let intensity: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glint: Double = 0
    @State private var haptics = TiltHapticEngine()

    func body(content: Content) -> some View {
        foiled(content)
            .hoverCard(intensity: intensity, onDrag: handle)
            .task(id: sweeping) { await runSweeps() }
    }

    /// The foil accents, applied to the flat art BEFORE `hoverCard` rotates the
    /// result — so the sheen and the glint travel with the card face.
    @ViewBuilder private func foiled(_ content: Content) -> some View {
        if band == .flat {
            content
        } else {
            content
                .glintSweep(progress: glint, width: 0.3)
                .tiltShimmer(strength: band.sheen * sheenScale, tint: band.tint)
        }
    }

    /// `intensity` shapes the motion budget, not the card's identity, so a
    /// calmer surface keeps most of its foil: the sheen only fades to 65%.
    private var sheenScale: Double {
        0.65 + 0.35 * min(max(intensity, 0), 1)
    }

    /// The periodic pass is pure decoration — Reduce Motion drops it, and so
    /// does a fully damped surface. The static sheen stays either way.
    private var sweeping: Bool { band.sweeps && !reduceMotion && intensity > 0 }

    private func handle(_ event: HoverCardDragEvent) {
        switch event {
        case let .began(x, y):
            haptics.began(x: x.degrees, y: y.degrees, intensity: intensity)
        case let .changed(x, y):
            haptics.changed(x: x.degrees, y: y.degrees)
        case .ended:
            haptics.ended()
        }
    }

    /// Sweeps a glint across the card every `sweepPeriod`. Cancelled and
    /// restarted whenever `sweeping` flips, which is what makes toggling
    /// Reduce Motion take effect without a reappearance.
    private func runSweeps() async {
        glint = 0
        guard sweeping else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(FoilBand.sweepPeriod))
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: FoilBand.sweepDuration)) { glint = 1 }
            try? await Task.sleep(for: .seconds(FoilBand.sweepDuration))
            guard !Task.isCancelled else { return }
            // Snap back off-view: `glintSweep` is a strict no-op at 0, so the
            // band costs nothing between passes.
            withTransaction(Transaction(animation: nil)) { glint = 0 }
        }
    }
}
