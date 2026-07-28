//
//  MotionUpdateSystem.swift
//  binderBuilder
//
//  Polls the MotionProvider once per frame and drives the card holo light
//  phase: as the device tilts, the iridescent rainbow + sparkle on every card
//  front (CardSurface.metal) sweeps — the signature foil effect, in 3D. The
//  phase is written into each front CustomMaterial's custom.value.zw (the
//  shader's lightPhase). A slow ambient drift keeps foils alive at rest; the
//  -holoPhase launch arg freezes the phase for deterministic screenshots.
//
//  Floating cards (CardFloatSystem) carry the same CardSlotComponent, so they
//  pick up the holo sweep too. Page sway / floating-card gravity drift hook
//  the same provider and are layered on as those systems land.
//

import RealityKit
import simd

@MainActor
final class MotionUpdateSystem: System {
    private static let query = EntityQuery(where: .has(CardSlotComponent.self))
    private static var didRegister = false

    /// Set by SceneBootstrap; the provider is render-thread safe to read.
    static var provider: (any MotionProvider)?
    /// -holoPhase override: freezes the light phase for screenshots.
    static var holoPhaseOverride: SIMD2<Float>?

    /// How strongly device tilt shifts the foil hue.
    static let tiltGain: Float = 0.6
    /// Ambient drift so foils shimmer even when the device is still (cycles/s).
    static let driftRate: Float = 0.04
    /// Period / duration / strength of the occasional shimmer sweep on the
    /// floating ("main") card.
    nonisolated static let shimmerPeriod: Float = 4.5
    nonisolated static let shimmerDuration: Float = 0.9
    nonisolated static let shimmerAmount: Float = 2.4
    /// Amplitude multiplier for the one-shot "first touch" glint bump played
    /// when a `CardFloatComponent.firstTouchGlint`-flagged card first floats.
    nonisolated static let firstFloatGlintMultiplier: Float = 1.8

    private var elapsed: Float = 0

    static func ensureRegistered() {
        guard !didRegister else { return }
        didRegister = true
        registerSystem()
    }

    init(scene: Scene) {}

    /// Maps a motion sample to the card foil light phase. Pure + nonisolated so
    /// it is unit-testable. The override (from -holoPhase) wins outright;
    /// otherwise device tilt away from the rest pose (gravity (0,-1,0)) sweeps
    /// the hue, with a slow ambient drift on the first axis.
    nonisolated static func holoPhase(
        sample: MotionSample,
        elapsed: Float,
        override: SIMD2<Float>?
    ) -> SIMD2<Float> {
        if let override { return override }
        let g = sample.gravity
        return SIMD2<Float>(
            g.x * tiltGain + elapsed * driftRate,
            g.z * tiltGain
        )
    }

    /// A periodic light-catch that sweeps the foil hue across the floating card
    /// (0 most of the time; a smooth out-and-back bump during each burst).
    nonisolated static func shimmerSweep(elapsed: Float) -> Float {
        let t = elapsed.truncatingRemainder(dividingBy: shimmerPeriod)
        guard t < shimmerDuration else { return 0 }
        return sin((t / shimmerDuration) * .pi) * shimmerAmount
    }

    /// The one-shot, non-repeating "first touch" glint: same envelope shape as
    /// `shimmerSweep` but bigger and never repeating — `progress` is the time
    /// (s) since the bump started, and it's spent (0) once it clears
    /// `shimmerDuration`, at which point the caller consumes the flag.
    nonisolated static func firstFloatGlint(progress: Float) -> Float {
        guard progress >= 0, progress < shimmerDuration else { return 0 }
        return sin((progress / shimmerDuration) * .pi) * shimmerAmount * firstFloatGlintMultiplier
    }

    func update(context: SceneUpdateContext) {
        elapsed += Float(context.deltaTime)

        let phase = Self.holoPhase(
            sample: Self.provider?.latest ?? .rest,
            elapsed: elapsed,
            override: Self.holoPhaseOverride
        )
        // Floating ("main") card gets an occasional extra shimmer sweep.
        let shimmer = Self.holoPhaseOverride == nil ? Self.shimmerSweep(elapsed: elapsed) : 0

        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard let card = entity as? ModelEntity,
                  var model = card.components[ModelComponent.self],
                  var material = model.materials.first as? CustomMaterial else { continue }
            var extra: Float = 0
            if var f = entity.components[CardFloatComponent.self] {
                if f.firstTouchGlint {
                    // A flagged card gets its one-shot bump instead of the
                    // periodic ambient shimmer, then the flag is consumed.
                    extra = Self.firstFloatGlint(progress: f.glintElapsed)
                    f.glintElapsed += Float(context.deltaTime)
                    if f.glintElapsed >= Self.shimmerDuration {
                        f.firstTouchGlint = false
                        f.glintElapsed = 0
                    }
                    entity.components.set(f)
                } else {
                    extra = shimmer
                }
            }
            let targetZ: Float = phase.x + extra
            var value = material.custom.value
            if value.z == targetZ && value.w == phase.y { continue }
            value.z = targetZ
            value.w = phase.y
            material.custom.value = value
            model.materials[0] = material
            card.components.set(model)
        }
    }
}
