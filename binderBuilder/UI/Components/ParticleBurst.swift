//
//  ParticleBurst.swift
//  binderBuilder
//
//  A one-shot celebratory burst, fired by bumping `trigger`. Drawn in a single
//  Canvas inside TimelineView(.animation) — one layer, no per-particle views —
//  so a chase-card reveal can throw 40 chips without touching the view graph.
//
//  Shapes are deliberately limited to rounded-rect confetti chips and 4-point
//  star glyphs (`ParticleShape` has no circle case, by design): generic
//  celebration visuals only, nothing that reads as another publisher's
//  artwork. Silent, non-interactive, and every particle is dead within
//  `BurstParticle.maxLifetime`.
//
//  Particles are generated from a seeded RNG keyed on `trigger`, so a given
//  trigger always produces the same burst — which is what makes it testable.
//

import SwiftUI

/// The only two particle silhouettes. Intentionally no circular/ball case —
/// see the file header. Order is asserted by ParticleBurstTests.
nonisolated enum ParticleShape: CaseIterable, Sendable {
    case chip
    case star
}

/// Deterministic splitmix64. Seeded from the burst trigger so replaying a
/// trigger replays the exact same burst.
nonisolated struct BurstRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: Int) {
        state = UInt64(bitPattern: Int64(seed))
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// One particle's whole life, resolved up front. Pure data: the Canvas
/// renderer derives position/opacity/scale from `elapsed` alone.
nonisolated struct BurstParticle: Sendable, Equatable {
    /// Launch direction, radians (0 = +x, screen coordinates so +y is down).
    var angle: Double
    /// Distance travelled from the origin over the full lifetime, in points.
    var distance: Double
    /// Nominal edge length at full scale, in points.
    var size: Double
    /// Rotation at birth, radians.
    var rotation: Double
    /// Total rotation over the lifetime, radians.
    var spin: Double
    /// Seconds until dead. Always within `minLifetime...maxLifetime`.
    var lifetime: Double
    /// Peak opacity, so the burst doesn't read as one flat sheet.
    var brightness: Double
    var shape: ParticleShape

    /// Hard ceiling on every particle's life. Keeps the burst inside the
    /// reveal choreography's beat budget — nothing outlives 420 ms.
    static let maxLifetime: Double = 0.42
    static let minLifetime: Double = 0.26
    /// Downward drift over the lifetime, in points — just enough weight.
    static let gravity: Double = 26

    /// Builds the burst for `trigger`. Deterministic: same trigger and
    /// intensity always yield the same particles. `intensity` is the particle
    /// count (clamped at zero).
    static func burst(trigger: Int, intensity: Int) -> [BurstParticle] {
        let count = max(0, intensity)
        guard count > 0 else { return [] }

        var rng = BurstRandom(seed: trigger)
        let slice = 2 * Double.pi / Double(count)
        return (0..<count).map { index in
            // Even angular spread plus jitter: a ring that never looks banded
            // and never leaves a bald patch.
            let jitter = Double.random(in: -slice / 2...slice / 2, using: &rng)
            return BurstParticle(
                angle: slice * Double(index) + jitter,
                distance: Double.random(in: 52...118, using: &rng),
                size: Double.random(in: 5...11, using: &rng),
                rotation: Double.random(in: 0..<(2 * .pi), using: &rng),
                spin: Double.random(in: -2.4...2.4, using: &rng),
                lifetime: Double.random(in: minLifetime...maxLifetime, using: &rng),
                brightness: Double.random(in: 0.62...1, using: &rng),
                shape: Bool.random(using: &rng) ? .chip : .star
            )
        }
    }

    /// Path for one particle, centred on the origin, at `side` points.
    static func path(shape: ParticleShape, side: Double) -> Path {
        switch shape {
        case .chip:
            let height = side * 0.62
            return Path(
                roundedRect: CGRect(x: -side / 2, y: -height / 2, width: side, height: height),
                cornerRadius: height * 0.35
            )
        case .star:
            // 4-point star: alternating outer/inner radii, 8 vertices.
            let outer = side * 0.62
            let inner = outer * 0.34
            return Path { path in
                for vertex in 0..<8 {
                    let radius = vertex.isMultiple(of: 2) ? outer : inner
                    let theta = -Double.pi / 2 + Double(vertex) * (.pi / 4)
                    let point = CGPoint(x: cos(theta) * radius, y: sin(theta) * radius)
                    if vertex == 0 {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
                path.closeSubpath()
            }
        }
    }

    /// Draws the burst at `elapsed` seconds. Draws nothing once every particle
    /// is dead, so a stale Canvas costs one loop and no geometry.
    static func draw(
        in context: inout GraphicsContext,
        size: CGSize,
        particles: [BurstParticle],
        elapsed: Double,
        tint: Color
    ) {
        let origin = CGPoint(x: size.width / 2, y: size.height / 2)
        for particle in particles {
            let t = elapsed / particle.lifetime
            guard t >= 0, t < 1 else { continue }

            // Travel eases out (fast launch, drifting stop); opacity and scale
            // decay on the mirrored cubic so the tail is a fade, not a snap.
            let inverse = 1 - t
            let decay = inverse * inverse * inverse
            let travel = 1 - decay
            let radius = particle.distance * travel
            let x = origin.x + cos(particle.angle) * radius
            let y = origin.y + sin(particle.angle) * radius + Self.gravity * t * t
            let scale = 0.55 + 0.45 * decay

            var path = Self.path(shape: particle.shape, side: particle.size * scale)
            path = path.applying(
                CGAffineTransform(rotationAngle: particle.rotation + particle.spin * t)
            )
            path = path.applying(CGAffineTransform(translationX: x, y: y))
            context.fill(path, with: .color(tint.opacity(decay * particle.brightness)))
        }
    }
}

/// A one-shot particle burst. Place in an overlay; it never takes hits and
/// renders nothing between bursts.
///
/// - Parameters:
///   - trigger: bump this to fire. Changing it restarts the burst.
///   - intensity: particle count.
///   - tint: particle colour (opacity is modulated per particle).
struct ParticleBurst: View {
    private let trigger: Int
    private let intensity: Int
    private let tint: Color

    init(trigger: Int, intensity: Int, tint: Color) {
        self.trigger = trigger
        self.intensity = intensity
        self.tint = tint
    }

    private struct Burst: Equatable {
        let id: Int
        let start: Date
        let particles: [BurstParticle]
    }

    @State private var burst: Burst?

    var body: some View {
        Group {
            if let burst {
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        BurstParticle.draw(
                            in: &context,
                            size: size,
                            particles: burst.particles,
                            elapsed: timeline.date.timeIntervalSince(burst.start),
                            tint: tint
                        )
                    }
                }
                .drawingGroup()
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, new in
            burst = Burst(
                id: new,
                start: .now,
                particles: BurstParticle.burst(trigger: new, intensity: intensity)
            )
        }
        .task(id: burst?.id) {
            guard burst != nil else { return }
            // Tear the TimelineView down once the last particle has died, so
            // an idle burst isn't holding a per-frame update open.
            try? await Task.sleep(for: .seconds(BurstParticle.maxLifetime))
            burst = nil
        }
    }
}
