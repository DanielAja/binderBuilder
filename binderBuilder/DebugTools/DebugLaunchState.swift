//
//  DebugLaunchState.swift
//  binderBuilder
//
//  Deterministic launch-argument overrides used by simulator verification
//  (screenshot-based milestone checks) and by the simulated motion provider.
//
//  Supported arguments:
//    -uiState <shelf|binderOpen|cardFloating>   force initial app mode
//    -curl <0.0...1.0>                          freeze the active page at a curl progress
//    -autoFlip                                  animate one full page flip after launch
//    -holoPhase <x,y>                           freeze holo light phase uniforms
//    -cardYaw <degrees>                         initial yaw for the floating card
//    -simulatedMotion                           force SimulatedMotionProvider (default on simulator)
//    -tilt <pitch,roll>                         initial simulated tilt in radians
//    -deformer <gpu|cpu>                        select PageDeformer implementation
//

import Foundation

struct DebugLaunchState {
    enum UIState: String {
        case shelf, binderOpen, cardFloating
    }

    enum Deformer: String {
        case gpu, cpu
    }

    let uiState: UIState?
    let curl: Float?
    let autoFlip: Bool
    let holoPhase: SIMD2<Float>?
    let cardYawDegrees: Float?
    let simulatedMotion: Bool
    let tilt: SIMD2<Float>?
    let deformer: Deformer?

    static let current = DebugLaunchState(arguments: ProcessInfo.processInfo.arguments)

    init(arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag),
                  arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        func float2(after flag: String) -> SIMD2<Float>? {
            guard let raw = value(after: flag) else { return nil }
            let parts = raw.split(separator: ",").compactMap { Float($0) }
            guard parts.count == 2 else { return nil }
            return SIMD2<Float>(parts[0], parts[1])
        }

        uiState = value(after: "-uiState").flatMap(UIState.init(rawValue:))
        curl = value(after: "-curl").flatMap(Float.init).map { min(max($0, 0), 1) }
        autoFlip = arguments.contains("-autoFlip")
        holoPhase = float2(after: "-holoPhase")
        cardYawDegrees = value(after: "-cardYaw").flatMap(Float.init)
        #if targetEnvironment(simulator)
        simulatedMotion = true
        #else
        simulatedMotion = arguments.contains("-simulatedMotion")
        #endif
        tilt = float2(after: "-tilt")
        deformer = value(after: "-deformer").flatMap(Deformer.init(rawValue:))
    }
}
