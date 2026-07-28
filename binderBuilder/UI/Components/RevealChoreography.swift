//
//  RevealChoreography.swift
//  binderBuilder
//
//  The timing model behind the post-scan reveal: what each card in a batch
//  does and exactly when. Pure Foundation so the beats are testable without a
//  view — the view only reads the marks and plays them.
//
//  Value drives the drama. A card's tier comes from its trading price using
//  the same $5 / $25 language as LiveScanModel's haptics, and the tier decides
//  how long the card hangs on screen, how heavy the burst is, and whether the
//  run pauses for a deliberate tap.
//
//  Reduce Motion keeps the *rhythm* and the haptics identical — same hangs,
//  same tap gate — and only collapses the flip and the glint onto the beat's
//  start, which the view reads as "crossfade instead of flip".
//

import Foundation

/// How much of a moment a pull deserves, derived from its price.
nonisolated enum RevealTier: String, Sendable, CaseIterable {
    case common
    case notable
    case chase

    /// `< $5` (and unpriced) common, `$5..<$25` notable, `>= $25` chase.
    static func tier(forPrice price: Double?) -> RevealTier {
        guard let price else { return .common }
        if price >= 25 { return .chase }
        if price >= 5 { return .notable }
        return .common
    }
}

/// One card queued for the reveal. Identity is per-appearance, not per-card, so
/// scanning the same card twice in a batch reveals it twice.
nonisolated struct RevealItem: Identifiable, Hashable, Sendable {
    var id = UUID()
    var cardID: String
    var name: String
    var imageBase: String?
    var price: Double?

    var tier: RevealTier { RevealTier.tier(forPrice: price) }
}

/// The marks for a single card's turn, all offsets absolute from the start of
/// the batch. `start` is the rip (haptic + burst), the flip/crossfade runs from
/// `flipStart`, the glint sweeps from `glintStart`, and `hang` is how long the
/// face holds before the run moves on.
nonisolated struct RevealBeat: Identifiable, Hashable, Sendable {
    let index: Int
    let tier: RevealTier
    let start: Duration
    let flipStart: Duration
    let glintStart: Duration
    let hang: Duration
    /// Chase pulls wait for the user instead of auto-advancing.
    let requiresTap: Bool

    var id: Int { index }
}

nonisolated enum RevealChoreography {
    /// Flip duration; the glint has to land inside this window.
    static let flip = Duration.milliseconds(380)
    /// Reduce Motion's stand-in for the flip.
    static let crossfade = Duration.milliseconds(180)
    /// Glint runs 150–400 ms into the beat, i.e. across the second half of the
    /// flip, when the face is turning toward the viewer.
    static let glintDelay = Duration.milliseconds(150)
    static let glintDuration = Duration.milliseconds(250)
    /// Breath between one card leaving and the next ripping.
    static let gap = Duration.milliseconds(120)

    /// How long the face holds once it's turned.
    static func hang(for tier: RevealTier) -> Duration {
        switch tier {
        case .common: .milliseconds(380)
        case .notable: .milliseconds(520)
        case .chase: .milliseconds(1400)
        }
    }

    /// Particle count behind the card at the rip.
    static func burstIntensity(for tier: RevealTier) -> Int {
        switch tier {
        case .common: 40
        case .notable: 90
        case .chase: 180
        }
    }

    /// Lays the batch out end to end: each card rips only once the previous
    /// card has finished turning and held, plus a gap. Chase beats set
    /// `requiresTap`, so the view stretches the gap by however long the user
    /// takes — the marks stay relative to each other either way.
    static func timeline(_ tiers: [RevealTier], reduceMotion: Bool) -> [RevealBeat] {
        var beats: [RevealBeat] = []
        beats.reserveCapacity(tiers.count)
        let turn = reduceMotion ? crossfade : flip
        var cursor = Duration.zero

        for (index, tier) in tiers.enumerated() {
            let hold = hang(for: tier)
            beats.append(RevealBeat(
                index: index,
                tier: tier,
                start: cursor,
                flipStart: cursor,
                glintStart: reduceMotion ? cursor : cursor + glintDelay,
                hang: hold,
                requiresTap: tier == .chase))
            cursor += turn + hold + gap
        }
        return beats
    }

    /// Convenience for the view: beats straight from the queued items.
    static func timeline(for items: [RevealItem], reduceMotion: Bool) -> [RevealBeat] {
        timeline(items.map(\.tier), reduceMotion: reduceMotion)
    }
}
