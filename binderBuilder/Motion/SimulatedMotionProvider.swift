//
//  SimulatedMotionProvider.swift
//  binderBuilder
//
//  Virtual MotionProvider for the simulator (and `-simulatedMotion` on
//  device). A programmatic target tilt — set by MotionDebugOverlay's
//  joystick or by tests — is chased with an exactly-integrated critically
//  damped spring, so the simulated attitude eases to its target with no
//  overshoot. `injectShake()` adds a decaying oscillatory userAcceleration
//  impulse. Gravity is derived by rotating `MotionSample.restGravity` by the
//  simulated attitude.
//
//  Tilt convention (radians):
//    pitch — rotation about the device/scene X axis (top of device away/toward you)
//    roll  — rotation about the device/scene Z axis (tilt left/right)
//    attitude = quat(roll, z) * quat(pitch, x); identity at zero tilt.
//
//  Time stepping: the consumer (MotionUpdateSystem) is expected to drive the
//  simulation deterministically by calling `tick(dt:)` once per frame. As a
//  standalone fallback, `start()` arms an internal 60 Hz timer that steps the
//  simulation only while no external `tick(dt:)` has arrived recently, so the
//  overlay stays live even before the 3D scene is wired up.
//
//  Threading: all simulation state lives behind an os_unfair_lock; `latest`,
//  `tick(dt:)`, `setTargetTilt`, and `injectShake()` are safe from any
//  thread. `start()`/`stop()` manage the fallback timer and should be called
//  from the main thread (the class is `@unchecked Sendable` for that one
//  unprotected property).
//

import Foundation
import os
import simd

nonisolated final class SimulatedMotionProvider: MotionProvider, @unchecked Sendable {

    private enum Tuning {
        /// Critically damped spring frequency (rad/s). Settles in ~0.5 s.
        static let springOmega: Float = 12
        /// Sanity clamp for tilt targets (debug tool, not a flight sim).
        static let maxTilt: Float = .pi / 2
        /// Peak userAcceleration added per shake, in G.
        static let shakeImpulse: Float = 1.6
        /// Total shake amplitude cap when shakes stack, in G.
        static let shakeCap: Float = 2.5
        /// Shake amplitude decay rate (1/s): e^-7 ≈ 0.1% after 1 s.
        static let shakeDecay: Float = 7
        /// Shake oscillation frequency (Hz).
        static let shakeFrequency: Float = 9
        /// Shake direction (normalized at use): mostly side-to-side.
        static let shakeAxis = SIMD3<Float>(1, 0, 0.35)
        /// Fallback timer period.
        static let timerInterval: TimeInterval = 1.0 / 60.0
        /// Fallback timer yields if an external tick arrived this recently.
        static let externalTickGrace: TimeInterval = 0.25
    }

    private struct State {
        var tilt: SIMD2<Float>            // (pitch, roll), radians
        var tiltVelocity: SIMD2<Float> = .zero
        var targetTilt: SIMD2<Float>
        var shakeAmplitude: Float = 0
        var shakePhase: Float = 0
        var time: TimeInterval = 0
        var lastExternalTickUptime: TimeInterval?
        var latest: MotionSample = .rest
    }

    private let state: OSAllocatedUnfairLock<State>
    private let timerQueue = DispatchQueue(
        label: "com.aja.binderBuilder.simulated-motion",
        qos: .userInteractive
    )
    /// Fallback timer; only touched from start()/stop() (main thread).
    private var fallbackTimer: DispatchSourceTimer?

    /// - Parameter initialTilt: starting (pitch, roll) in radians; the
    ///   factory passes `DebugLaunchState.current.tilt` so `-tilt p,r`
    ///   launches pre-tilted. The spring holds this tilt until a new target
    ///   is set.
    init(initialTilt: SIMD2<Float>? = nil) {
        let tilt = (initialTilt ?? .zero).clamped(to: Tuning.maxTilt)
        var initial = State(tilt: tilt, targetTilt: tilt)
        initial.latest = Self.sample(for: initial)
        state = OSAllocatedUnfairLock(initialState: initial)
    }

    // MARK: MotionProvider

    var latest: MotionSample {
        state.withLock { $0.latest }
    }

    /// Arms the standalone 60 Hz fallback timer. Call from the main thread.
    func start() {
        guard fallbackTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(
            deadline: .now() + Tuning.timerInterval,
            repeating: Tuning.timerInterval,
            leeway: .milliseconds(2)
        )
        timer.setEventHandler { [weak self] in
            self?.fallbackTimerFired()
        }
        timer.resume()
        fallbackTimer = timer
    }

    /// Cancels the fallback timer. Call from the main thread.
    func stop() {
        fallbackTimer?.cancel()
        fallbackTimer = nil
    }

    // MARK: Simulation inputs (thread-safe)

    /// Current smoothed (pitch, roll) in radians.
    var currentTilt: SIMD2<Float> {
        state.withLock { $0.tilt }
    }

    /// Sets the tilt the spring chases. Safe from any thread.
    func setTargetTilt(pitch: Float, roll: Float) {
        let target = SIMD2<Float>(pitch, roll).clamped(to: Tuning.maxTilt)
        state.withLock { $0.targetTilt = target }
    }

    /// Adds a decaying side-to-side userAcceleration impulse (stacks up to a
    /// cap). Safe from any thread.
    func injectShake() {
        state.withLock { s in
            s.shakeAmplitude = min(s.shakeAmplitude + Tuning.shakeImpulse, Tuning.shakeCap)
            s.shakePhase = 0
            s.latest = Self.sample(for: s)
        }
    }

    /// Advances the simulation by `dt` seconds. Deterministic — intended to
    /// be driven once per frame by the consuming RealityKit System (and by
    /// tests). While being called, the internal fallback timer stands down.
    func tick(dt: TimeInterval) {
        advance(dt: dt, external: true)
    }

    // MARK: Simulation core

    private func fallbackTimerFired() {
        let now = ProcessInfo.processInfo.systemUptime
        let externallyDriven = state.withLock { s in
            if let last = s.lastExternalTickUptime {
                return now - last < Tuning.externalTickGrace
            }
            return false
        }
        guard !externallyDriven else { return }
        advance(dt: Tuning.timerInterval, external: false)
    }

    private func advance(dt: TimeInterval, external: Bool) {
        guard dt > 0 else { return }
        let dt = min(dt, 0.25) // survive hitches without exploding
        let uptime = external ? ProcessInfo.processInfo.systemUptime : nil
        state.withLock { s in
            if let uptime { s.lastExternalTickUptime = uptime }

            // Exact integration of a critically damped spring over dt:
            //   x(t) = target + (Δ0 + (v0 + ω·Δ0)·t)·e^(-ω·t)
            // Stepwise-exact (the solution is a semigroup), so starting from
            // rest it approaches the target monotonically — zero overshoot.
            let fdt = Float(dt)
            let omega = Tuning.springOmega
            let decay = exp(-omega * fdt)
            let delta = s.tilt - s.targetTilt
            let temp = (s.tiltVelocity + omega * delta) * fdt
            s.tilt = s.targetTilt + (delta + temp) * decay
            s.tiltVelocity = (s.tiltVelocity - omega * temp) * decay

            // Decaying shake oscillator.
            if s.shakeAmplitude > 0 {
                s.shakePhase += 2 * .pi * Tuning.shakeFrequency * fdt
                s.shakeAmplitude *= exp(-Tuning.shakeDecay * fdt)
                if s.shakeAmplitude < 1e-4 {
                    s.shakeAmplitude = 0
                    s.shakePhase = 0
                }
            }

            s.time += dt
            s.latest = Self.sample(for: s)
        }
    }

    private static func sample(for state: State) -> MotionSample {
        let attitude = attitudeQuaternion(pitch: state.tilt.x, roll: state.tilt.y)
        let gravity = attitude.act(MotionSample.restGravity)
        let acceleration: SIMD3<Float>
        if state.shakeAmplitude > 0 {
            acceleration = simd_normalize(Tuning.shakeAxis)
                * (state.shakeAmplitude * cos(state.shakePhase))
        } else {
            acceleration = .zero
        }
        return MotionSample(
            gravity: gravity,
            userAcceleration: acceleration,
            attitude: attitude,
            timestamp: state.time
        )
    }

    /// attitude = roll about Z, then pitch about X (applied right-to-left).
    static func attitudeQuaternion(pitch: Float, roll: Float) -> simd_quatf {
        let pitchQ = simd_quatf(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
        let rollQ = simd_quatf(angle: roll, axis: SIMD3<Float>(0, 0, 1))
        return rollQ * pitchQ
    }
}

private nonisolated extension SIMD2<Float> {
    func clamped(to limit: Float) -> SIMD2<Float> {
        simd_clamp(self, SIMD2<Float>(repeating: -limit), SIMD2<Float>(repeating: limit))
    }
}
