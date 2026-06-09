//
//  MotionTests.swift
//  binderBuilderTests
//
//  Deterministic tests for the Motion module: rest constants, the
//  critically damped tilt spring, attitude-derived gravity, and shake decay.
//  SimulatedMotionProvider is stepped via tick(dt:) — no timers, no clocks.
//

import Foundation
import simd
import Testing
@testable import binderBuilder

struct MotionTests {

    private static let dt: TimeInterval = 1.0 / 60.0

    // MARK: MotionSample

    @Test func restSampleConstantsAreSane() {
        let rest = MotionSample.rest
        #expect(rest.gravity == SIMD3<Float>(0, -1, 0))
        #expect(abs(simd_length(rest.gravity) - 1) < 1e-6)
        #expect(rest.userAcceleration == .zero)
        #expect(rest.timestamp == 0)
        // Identity attitude leaves vectors unchanged.
        let v = SIMD3<Float>(0.3, -0.7, 0.2)
        #expect(simd_length(rest.attitude.act(v) - v) < 1e-6)
    }

    @Test func providersStartAtRest() {
        #expect(SimulatedMotionProvider().latest == MotionSample.rest)
        // Simulator has no device motion, so this provider must stay at rest.
        let device = DeviceMotionProvider()
        device.start()
        #expect(device.latest == MotionSample.rest)
        device.stop()
    }

    // MARK: Tilt spring

    @Test func springConvergesToTargetWithinTwoSeconds() {
        let provider = SimulatedMotionProvider()
        provider.setTargetTilt(pitch: 0.4, roll: -0.3)
        for _ in 0..<120 { // 2 s of 60 Hz ticks
            provider.tick(dt: Self.dt)
        }
        let tilt = provider.currentTilt
        #expect(abs(tilt.x - 0.4) < 0.005)
        #expect(abs(tilt.y - (-0.3)) < 0.005)
        // Timestamp advanced by simulated time.
        #expect(abs(provider.latest.timestamp - 2.0) < 1e-9)
    }

    @Test func springIsCriticallyDampedWithoutOvershoot() {
        let provider = SimulatedMotionProvider()
        let target: Float = 0.4
        provider.setTargetTilt(pitch: target, roll: 0)
        var maxPitch: Float = -.infinity
        for _ in 0..<240 { // 4 s — plenty of time to expose any ringing
            provider.tick(dt: Self.dt)
            maxPitch = max(maxPitch, provider.currentTilt.x)
        }
        #expect(maxPitch <= target * 1.05, "overshoot beyond 5%: peaked at \(maxPitch)")
        #expect(abs(provider.currentTilt.x - target) < 0.005)
    }

    @Test func springReturnsToZeroAfterTargetReset() {
        let provider = SimulatedMotionProvider(initialTilt: SIMD2<Float>(0.5, -0.5))
        provider.setTargetTilt(pitch: 0, roll: 0)
        for _ in 0..<120 {
            provider.tick(dt: Self.dt)
        }
        #expect(simd_length(provider.currentTilt) < 0.005)
        #expect(simd_length(provider.latest.gravity - MotionSample.restGravity) < 0.01)
    }

    // MARK: Gravity from attitude

    @Test func gravityFollowsThirtyDegreeRoll() {
        let roll = Float.pi / 6
        let provider = SimulatedMotionProvider(initialTilt: SIMD2<Float>(0, roll))
        let gravity = provider.latest.gravity
        // restGravity (0,-1,0) rotated +30° about Z → (sin 30°, -cos 30°, 0).
        #expect(abs(gravity.x - 0.5) < 1e-4)
        #expect(abs(gravity.y - (-0.866_025_4)) < 1e-4)
        #expect(abs(gravity.z) < 1e-5)
        #expect(abs(simd_length(gravity) - 1) < 1e-5)
        // Attitude matches a pure +30° roll about Z.
        let expected = simd_quatf(angle: roll, axis: SIMD3<Float>(0, 0, 1))
        let attitude = provider.latest.attitude
        #expect(abs(simd_dot(attitude.vector, expected.vector)) > 0.999_99)
    }

    // MARK: Shake

    @Test func shakeImpulseDecaysBelowEpsilonWithinOneSecond() {
        let provider = SimulatedMotionProvider()
        provider.injectShake()
        #expect(simd_length(provider.latest.userAcceleration) > 0.1,
                "shake should kick immediately")
        provider.tick(dt: Self.dt)
        #expect(simd_length(provider.latest.userAcceleration) > 0.1,
                "shake should still be strong after one frame")
        for _ in 0..<59 { // complete 1 s of simulated time
            provider.tick(dt: Self.dt)
        }
        #expect(simd_length(provider.latest.userAcceleration) < 0.01,
                "shake should decay below epsilon within 1 s")
        // Shake must not disturb the tilt spring.
        #expect(simd_length(provider.currentTilt) < 1e-6)
    }

    // MARK: Factory

    @Test func factoryReturnsSimulatedProviderOnSimulator() {
        // DebugLaunchState forces simulatedMotion = true on the simulator.
        let provider = MotionProviderFactory.make()
        #expect(provider is SimulatedMotionProvider)
    }

    @Test func factorySeedsInitialTiltFromLaunchState() throws {
        let launchState = DebugLaunchState(arguments: [
            "app", "-simulatedMotion", "-tilt", "0.2,-0.1",
        ])
        let provider = MotionProviderFactory.make(launchState: launchState)
        let simulated = try #require(provider as? SimulatedMotionProvider)
        #expect(simulated.currentTilt == SIMD2<Float>(0.2, -0.1))
    }
}
