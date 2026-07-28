//
//  ParticleBurstTests.swift
//  binderBuilderTests
//
//  The celebration burst: deterministic from its trigger, budgeted to 420 ms,
//  and — the legal invariant — built from chips and stars only, never balls.
//

import SwiftUI
import Testing
@testable import binderBuilder

@Suite struct ParticleBurstTests {

    /// The no-ball invariant: nothing in the burst may read as a ball. The
    /// enum has no circular case at all, so it cannot regress by accident.
    @Test func shapesAreChipAndStarOnly() {
        #expect(ParticleShape.allCases == [.chip, .star])
    }

    @Test func countMatchesIntensity() {
        for intensity in [1, 8, 24, 40] {
            #expect(BurstParticle.burst(trigger: 7, intensity: intensity).count == intensity)
        }
    }

    @Test func nonPositiveIntensityYieldsNothing() {
        #expect(BurstParticle.burst(trigger: 7, intensity: 0).isEmpty)
        #expect(BurstParticle.burst(trigger: 7, intensity: -5).isEmpty)
    }

    @Test func sameTriggerReplaysTheSameBurst() {
        let first = BurstParticle.burst(trigger: 3, intensity: 18)
        let second = BurstParticle.burst(trigger: 3, intensity: 18)
        #expect(first == second)
    }

    @Test func differentTriggersDiffer() {
        let a = BurstParticle.burst(trigger: 3, intensity: 18)
        let b = BurstParticle.burst(trigger: 4, intensity: 18)
        #expect(a != b)
    }

    @Test func everyParticleDiesWithinBudget() {
        for trigger in 0..<32 {
            for particle in BurstParticle.burst(trigger: trigger, intensity: 24) {
                #expect(particle.lifetime <= 0.42)
                #expect(particle.lifetime >= BurstParticle.minLifetime)
            }
        }
    }

    @Test func particlesSpreadAroundTheFullCircle() {
        let particles = BurstParticle.burst(trigger: 11, intensity: 16)
        // Even slices plus bounded jitter: every quadrant gets particles.
        let quadrants = Set(particles.map { particle -> Int in
            let turns = particle.angle / (2 * Double.pi)
            let wrapped = turns - turns.rounded(.down)
            return Int(wrapped * 4)
        })
        #expect(quadrants.count == 4)
    }

    @Test func bothShapesAppearInATypicalBurst() {
        let shapes = Set(BurstParticle.burst(trigger: 5, intensity: 40).map(\.shape))
        #expect(shapes == Set(ParticleShape.allCases))
    }

    @Test func seededGeneratorIsStableForASeed() {
        var a = BurstRandom(seed: 99)
        var b = BurstRandom(seed: 99)
        let first = (0..<8).map { _ in a.next() }
        let second = (0..<8).map { _ in b.next() }
        #expect(first == second)

        var other = BurstRandom(seed: 100)
        #expect(other.next() != first[0])
    }

    @Test func pathsAreNonEmptyForBothShapes() {
        for shape in ParticleShape.allCases {
            #expect(!BurstParticle.path(shape: shape, side: 10).isEmpty)
        }
    }
}
