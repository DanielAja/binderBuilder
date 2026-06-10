//
//  MotionHoloTests.swift
//  binderBuilderTests
//
//  The motion -> card foil light-phase mapping.
//

import Testing
import simd
@testable import binderBuilder

@Suite struct MotionHoloTests {
    @Test func overrideWinsOutright() {
        let phase = MotionUpdateSystem.holoPhase(
            sample: .rest, elapsed: 12.3, override: SIMD2<Float>(0.5, 0.3)
        )
        #expect(phase == SIMD2<Float>(0.5, 0.3))
    }

    @Test func restOnlyDrifts() {
        let phase = MotionUpdateSystem.holoPhase(sample: .rest, elapsed: 0, override: nil)
        // gravity (0,-1,0) -> x and z tilt are zero; elapsed 0 -> no drift.
        #expect(abs(phase.x) < 1e-6)
        #expect(abs(phase.y) < 1e-6)
    }

    @Test func lateralTiltSweepsHue() {
        var tilted = MotionSample.rest
        tilted.gravity = SIMD3<Float>(0.5, -0.85, 0.1)
        let phase = MotionUpdateSystem.holoPhase(sample: tilted, elapsed: 0, override: nil)
        #expect(phase.x > 0)            // lateral tilt drives axis 0
        #expect(phase.y > 0)            // depth tilt drives axis 1
    }

    @Test func ambientDriftAdvancesWithTime() {
        let early = MotionUpdateSystem.holoPhase(sample: .rest, elapsed: 1, override: nil)
        let later = MotionUpdateSystem.holoPhase(sample: .rest, elapsed: 5, override: nil)
        #expect(later.x > early.x)
    }
}
