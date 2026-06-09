//
//  DeviceMotionProvider.swift
//  binderBuilder
//
//  Real-device MotionProvider backed by CMMotionManager (60 Hz device
//  motion, .xArbitraryZVertical reference frame).
//
//  Threading: CoreMotion delivers updates on the main queue; each update
//  writes the mapped sample into an os_unfair_lock-protected slot that the
//  render thread polls via `latest`. The class is `@unchecked Sendable`
//  because CMMotionManager itself is not Sendable — it is only ever touched
//  from `start()`/`stop()` (main thread) while all cross-thread state lives
//  behind the lock.
//
//  On hardware without device motion (and on the simulator, where
//  `isDeviceMotionAvailable` is false) `start()` is a no-op and the provider
//  keeps reporting `MotionSample.rest`. The factory normally picks
//  SimulatedMotionProvider in those environments anyway.
//

import CoreMotion
import Foundation
import os
import simd

nonisolated final class DeviceMotionProvider: MotionProvider, @unchecked Sendable {

    private let motionManager = CMMotionManager()
    private let latestSample = OSAllocatedUnfairLock(initialState: MotionSample.rest)

    var latest: MotionSample {
        latestSample.withLock { $0 }
    }

    /// Call from the main thread. No-op when device motion is unavailable
    /// (e.g. simulator) or updates are already running.
    func start() {
        guard motionManager.isDeviceMotionAvailable,
              !motionManager.isDeviceMotionActive else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        let latestSample = self.latestSample
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { motion, _ in
            guard let motion else { return }
            let sample = MotionSample(deviceMotion: motion)
            latestSample.withLock { $0 = sample }
        }
    }

    /// Call from the main thread. `latest` keeps returning the last sample.
    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }
}

nonisolated extension MotionSample {
    /// Maps CoreMotion's device frame straight through: +x right, +y toward
    /// the top of the device, +z out of the screen. In the reference pose
    /// (portrait, screen facing the user) CoreMotion reports gravity
    /// ≈ (0, -1, 0) G, which matches `MotionSample.restGravity` directly.
    /// Attitude is relative to the .xArbitraryZVertical reference frame.
    init(deviceMotion motion: CMDeviceMotion) {
        let g = motion.gravity
        let a = motion.userAcceleration
        let q = motion.attitude.quaternion
        self.init(
            gravity: SIMD3<Float>(Float(g.x), Float(g.y), Float(g.z)),
            userAcceleration: SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z)),
            attitude: simd_quatf(ix: Float(q.x), iy: Float(q.y), iz: Float(q.z), r: Float(q.w)),
            timestamp: motion.timestamp
        )
    }
}
