//
//  MotionProviderFactory.swift
//  binderBuilder
//
//  Picks the MotionProvider for this launch:
//  - SimulatedMotionProvider when DebugLaunchState.current.simulatedMotion
//    is set (always true on the simulator; `-simulatedMotion` on device),
//    seeded from `-tilt pitch,roll` when present.
//  - DeviceMotionProvider (CMMotionManager) otherwise.
//
//  MainActor (project default): reads DebugLaunchState at the call site.
//  The returned provider itself is nonisolated and render-thread safe.
//

import Foundation

enum MotionProviderFactory {
    /// Creates (but does not start) the provider appropriate for the given
    /// launch state. Callers own the lifecycle: call `start()` when the 3D
    /// scene appears and `stop()` when it disappears.
    static func make(launchState: DebugLaunchState = .current) -> any MotionProvider {
        if launchState.simulatedMotion {
            return SimulatedMotionProvider(initialTilt: launchState.tilt)
        }
        return DeviceMotionProvider()
    }
}
