//
//  TiltShimmerTests.swift
//  binderBuilderTests
//
//  MotionPhaseSource — the 2D sheen's phase feed. It must agree with the 3D
//  foil (MotionUpdateSystem.holoPhase) exactly, and its display link must be
//  ref-counted so several tiltShimmer() views share one.
//

import Testing
import simd
@testable import binderBuilder

/// Reports one fixed sample forever, so phase assertions are exact.
private nonisolated final class StubMotionProvider: MotionProvider {
    let latest: MotionSample
    init(_ sample: MotionSample) { latest = sample }
    func start() {}
    func stop() {}
}

@MainActor
@Suite struct TiltShimmerTests {

    private func tiltedSample() -> MotionSample {
        var sample = MotionSample.rest
        // Same fixture as MotionHoloTests.lateralTiltSweepsHue.
        sample.gravity = SIMD3<Float>(0.5, -0.85, 0.1)
        return sample
    }

    @Test func phaseMatchesHoloPhaseForFixedSample() {
        let sample = tiltedSample()
        let source = MotionPhaseSource(provider: StubMotionProvider(sample))

        // 0.25 is exact in binary and is also the hitch clamp, so `elapsed`
        // is comparable without a tolerance.
        source.step(dt: 0.25)

        #expect(source.elapsed == 0.25)
        #expect(source.phase == MotionUpdateSystem.holoPhase(
            sample: sample, elapsed: 0.25, override: nil
        ))
        #expect(source.phase.x > 0)  // lateral tilt drives axis 0
        #expect(source.phase.y > 0)  // depth tilt drives axis 1
    }

    @Test func restSampleStartsAtZeroAndDrifts() {
        let source = MotionPhaseSource(provider: StubMotionProvider(.rest))
        #expect(source.phase == SIMD2<Float>(0, 0))

        source.step(dt: 0.25)
        let early = source.phase
        source.step(dt: 0.25)

        #expect(source.elapsed == 0.5)
        #expect(source.phase.x > early.x)   // ambient drift keeps foils alive
        #expect(abs(source.phase.y) < 1e-6) // no tilt -> no depth phase
    }

    @Test func stepIgnoresNonPositiveDelta() {
        let source = MotionPhaseSource(provider: StubMotionProvider(tiltedSample()))
        source.step(dt: 0)
        source.step(dt: -1)
        #expect(source.elapsed == 0)
        #expect(source.phase == SIMD2<Float>(0, 0))
    }

    @Test func hitchesAreClamped() {
        let source = MotionPhaseSource(provider: StubMotionProvider(.rest))
        source.step(dt: 30)
        #expect(source.elapsed == 0.25)
    }

    @Test func startStopIsRefCounted() {
        let source = MotionPhaseSource(provider: StubMotionProvider(.rest))
        #expect(!source.isRunning)

        source.start()
        source.start()
        #expect(source.isRunning)
        #expect(source.subscriberCount == 2)

        source.stop()
        #expect(source.isRunning)  // one subscriber left

        source.stop()
        #expect(!source.isRunning)
        #expect(source.subscriberCount == 0)
    }

    @Test func unbalancedStopDoesNotGoNegative() {
        let source = MotionPhaseSource(provider: StubMotionProvider(.rest))
        source.stop()
        source.stop()
        #expect(source.subscriberCount == 0)
        #expect(!source.isRunning)

        source.start()
        #expect(source.isRunning)
        source.stop()
        #expect(!source.isRunning)
    }
}
