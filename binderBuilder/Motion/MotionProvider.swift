//
//  MotionProvider.swift
//  binderBuilder
//
//  Device-motion abstraction polled once per frame by the RealityKit
//  MotionUpdateSystem (Scene3D, wired in a later phase). Consumers: page
//  sway, floating-card gravity drift, holo light phase.
//
//  Threading model
//  ---------------
//  RealityKit systems run on the render thread, so `latest` MUST be safe to
//  read from any thread at any time. Implementations keep the most recent
//  sample behind an os_unfair_lock (`OSAllocatedUnfairLock`) — a single
//  uncontended lock acquisition per frame, no allocation, no async hops.
//  The protocol and both implementations are `nonisolated` (this project
//  defaults to MainActor isolation) and `Sendable` so a provider instance
//  can be handed to a RealityKit System directly.
//

import Foundation
import simd

/// One snapshot of device motion, expressed in scene terms (Y-up):
///
/// - `gravity`: unit-ish gravity direction in the device's frame, measured in
///   G. At rest in the reference pose (portrait, screen facing the user) this
///   is `(0, -1, 0)` — straight down the scene's Y axis.
/// - `userAcceleration`: device acceleration with gravity removed, in G.
///   Zero at rest; spikes when the user shakes the device.
/// - `attitude`: device orientation relative to the reference pose.
///   Identity at rest.
/// - `timestamp`: seconds, monotonically increasing while the provider runs.
///   Real providers use the CoreMotion epoch; simulated providers use
///   accumulated tick time. Only deltas are meaningful.
nonisolated struct MotionSample: Sendable, Equatable {
    var gravity: SIMD3<Float>
    var userAcceleration: SIMD3<Float>
    var attitude: simd_quatf
    var timestamp: TimeInterval

    /// Gravity direction when the device sits in the reference pose.
    static let restGravity = SIMD3<Float>(0, -1, 0)

    /// Identity attitude (reference pose).
    static let identityAttitude = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    /// The sample every provider reports before its first update: device
    /// perfectly at rest in the reference pose.
    static let rest = MotionSample(
        gravity: restGravity,
        userAcceleration: .zero,
        attitude: identityAttitude,
        timestamp: 0
    )
}

/// Source of per-frame device motion.
///
/// - `latest` is lock-protected and safe to call from any thread, including
///   the RealityKit render thread; it never blocks for more than the other
///   side's read/write of one small struct.
/// - `start()` / `stop()` should be called from the main thread (app
///   lifecycle code); they are cheap and idempotent.
nonisolated protocol MotionProvider: AnyObject, Sendable {
    /// Most recent motion sample; `MotionSample.rest` until the first update.
    var latest: MotionSample { get }

    /// Begin producing samples. Idempotent.
    func start()

    /// Stop producing samples. `latest` keeps returning the last sample.
    func stop()
}
