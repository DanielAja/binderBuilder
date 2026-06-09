//
//  DebugSceneOverrides.swift
//  binderBuilder
//
//  Launch-arg-driven scene additions for milestone verification.
//  SceneBootstrap calls this after assembling the standard scene; feature
//  modules extend it to stage their own deterministic preview content
//  (e.g. holo card previews) without editing SceneBootstrap itself.
//

import RealityKit

enum DebugSceneOverrides {
    static func apply(to root: Entity, cameraRig: CameraRig, launchState: DebugLaunchState) {
        // Feature preview hooks register below as later phases land.
    }
}
