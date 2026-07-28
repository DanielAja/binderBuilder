//
//  MotionPhaseSource.swift
//  binderBuilder
//
//  The 2D twin of MotionUpdateSystem: publishes the card foil light phase to
//  SwiftUI so flat card art can catch the light the same way the 3D cards do.
//
//  It is deliberately NOT a second motion pipeline. It polls the same
//  MotionProvider (from MotionProviderFactory) and maps samples through the
//  same pure `MotionUpdateSystem.holoPhase(sample:elapsed:override:)`, so a
//  `-holoPhase` launch arg freezes the 2D sheen and the 3D foil identically.
//
//  Lifecycle: `start()`/`stop()` are ref-counted, so several `tiltShimmer()`
//  views on screen share one 30 Hz CADisplayLink and the provider stops the
//  moment the last one goes away. 30 Hz is ample for a slow sheen and leaves
//  the frame budget to the RealityKit scene.
//
//  MainActor: SwiftUI-facing. The display link fires on the main run loop.
//

import Foundation
import Observation
import QuartzCore
import SwiftUI
import simd

@MainActor @Observable final class MotionPhaseSource {

    /// Shared by every `tiltShimmer()` on screen.
    static let shared = MotionPhaseSource()

    /// Sheen refresh rate. A highlight this slow reads identically at 30 Hz.
    static let frameRate: Float = 30

    /// Current foil light phase, as produced by `MotionUpdateSystem.holoPhase`.
    private(set) var phase: SIMD2<Float> = .zero

    /// Seconds of accumulated run time; feeds the ambient drift term.
    private(set) var elapsed: Float = 0

    @ObservationIgnored private var subscribers = 0
    @ObservationIgnored private var provider: (any MotionProvider)?
    @ObservationIgnored private let injectedProvider: (any MotionProvider)?
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var lastTimestamp: CFTimeInterval = 0

    /// - Parameter provider: overrides the factory's choice. Tests inject a
    ///   fixed-sample provider and drive `step(dt:)` by hand.
    init(provider: (any MotionProvider)? = nil) {
        injectedProvider = provider
    }

    /// Whether the display link is live. Ref-counted — see `start()`.
    var isRunning: Bool { displayLink != nil }

    /// Number of outstanding `start()` calls.
    var subscriberCount: Int { subscribers }

    /// Adds a subscriber; starts the provider and display link on the first
    /// one. Balance every call with `stop()`.
    func start() {
        subscribers += 1
        guard subscribers == 1, displayLink == nil else { return }

        resolvedProvider().start()
        lastTimestamp = 0

        let proxy = DisplayLinkProxy { [weak self] link in
            self?.displayLinkFired(link)
        }
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 15, maximum: Self.frameRate, preferred: Self.frameRate
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Removes a subscriber; stops the provider and display link when the last
    /// one goes away. Unbalanced calls are ignored rather than going negative.
    func stop() {
        guard subscribers > 0 else { return }
        subscribers -= 1
        guard subscribers == 0 else { return }

        // Invalidating releases the display link's retain on the proxy, which
        // is the only thing keeping the frame closure alive.
        displayLink?.invalidate()
        displayLink = nil
        provider?.stop()
    }

    /// Advances `elapsed` by `dt` and republishes the phase. Called once per
    /// display-link frame; tests call it directly for deterministic stepping.
    func step(dt: TimeInterval) {
        guard dt > 0 else { return }
        elapsed += Float(min(dt, 0.25))  // survive hitches without a hue jump
        phase = MotionUpdateSystem.holoPhase(
            sample: resolvedProvider().latest,
            elapsed: elapsed,
            override: MotionUpdateSystem.holoPhaseOverride
        )
    }

    private func displayLinkFired(_ link: CADisplayLink) {
        let dt = lastTimestamp == 0 ? link.duration : link.timestamp - lastTimestamp
        lastTimestamp = link.timestamp
        step(dt: dt)
    }

    private func resolvedProvider() -> any MotionProvider {
        if let provider { return provider }
        let made = injectedProvider ?? MotionProviderFactory.make()
        provider = made
        return made
    }
}

/// CADisplayLink retains its target, so the target is this stub rather than
/// the source itself; `invalidate()` is then the single thing that has to
/// break the chain.
private final class DisplayLinkProxy: NSObject {
    private let onFrame: (CADisplayLink) -> Void

    init(onFrame: @escaping (CADisplayLink) -> Void) {
        self.onFrame = onFrame
    }

    @objc func frame(_ link: CADisplayLink) {
        onFrame(link)
    }
}

// MARK: - tiltShimmer

extension View {
    /// Lays a motion-driven angular sheen over this view: as the device tilts,
    /// the highlight rotates across the art, the way light travels over a foil
    /// card. Under Reduce Motion the same gradient is applied statically.
    func tiltShimmer() -> some View {
        modifier(TiltShimmerModifier())
    }
}

private struct TiltShimmerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var subscribed = false

    /// Two highlights per revolution, wrapping to the same stop at both ends
    /// so the gradient has no seam.
    private static let stops = Gradient(colors: [
        .clear,
        .white.opacity(0.34),
        .clear,
        .white.opacity(0.14),
        .clear,
    ])

    private var angle: Angle {
        guard !reduceMotion else { return .degrees(-38) }
        let phase = MotionPhaseSource.shared.phase
        return .degrees(Double(phase.x) * 180 + Double(phase.y) * 90)
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                AngularGradient(gradient: Self.stops, center: .center, angle: angle)
                    .blendMode(.plusLighter)
                    .mask { content }
                    .allowsHitTesting(false)
            }
            .onAppear { setSubscribed(!reduceMotion) }
            .onDisappear { setSubscribed(false) }
            .onChange(of: reduceMotion) { _, reduced in setSubscribed(!reduced) }
    }

    /// Keeps this view's contribution to the source's ref count at exactly 0
    /// or 1, however the appearance/accessibility callbacks interleave.
    private func setSubscribed(_ wanted: Bool) {
        guard wanted != subscribed else { return }
        subscribed = wanted
        if wanted {
            MotionPhaseSource.shared.start()
        } else {
            MotionPhaseSource.shared.stop()
        }
    }
}
