//
//  CameraRig.swift
//  binderBuilder
//
//  Owns the virtual PerspectiveCamera on a rig parent entity, provides
//  framing presets, and unprojects screen points into world-space rays
//  (used by gesture picking in later phases). The ray math is a pure
//  nonisolated static function so it is unit-testable without a scene.
//

import CoreGraphics
import Foundation
import RealityKit
import simd

@MainActor
final class CameraRig {
    /// Parent entity ("the rig"); animate this to dolly the camera.
    let root: Entity
    /// The actual perspective camera, child of `root`.
    let camera: PerspectiveCamera
    /// Vertical field of view in degrees (kept in sync with the camera component).
    private(set) var fovDegrees: Float

    init(fovDegrees: Float = 55) {
        self.fovDegrees = fovDegrees
        root = Entity()
        root.name = "CameraRig"
        camera = PerspectiveCamera()
        camera.name = "Camera"
        camera.camera.fieldOfViewInDegrees = fovDegrees
        camera.camera.near = 0.005
        camera.camera.far = 30
        root.addChild(camera)
        applyBinderOpenFraming()
    }

    /// Named camera framings for the two top-level scenes.
    enum Framing {
        /// Open binder lying at the origin.
        case binderOpen
        /// Shelf with the standing binder + display cases (binder ~1 m away).
        case shelf

        var at: SIMD3<Float> {
            switch self {
            case .binderOpen: return SIMD3<Float>(0, 0.02, -0.02)
            case .shelf: return SIMD3<Float>(0, 0.30, 0.05)
            }
        }
        var from: SIMD3<Float> {
            switch self {
            case .binderOpen: return SIMD3<Float>(0, 0.78, 0.60)
            case .shelf: return SIMD3<Float>(0, 0.62, 1.75)
            }
        }
    }

    /// Frames the open binder (lying at the origin, ~0.53 m wide) in portrait:
    /// camera above and in front, looking down at ~52 degrees.
    func applyBinderOpenFraming() {
        apply(.binderOpen)
    }

    /// Snaps the camera to a framing immediately.
    func apply(_ framing: Framing) {
        camera.look(at: framing.at, from: framing.from, relativeTo: root)
    }

    /// Orbits the shelf framing by yaw (around world up) and pitch (around the
    /// camera's right axis), keeping the shelf focus centered. Used by the
    /// shelf pan gesture.
    func setShelfOrbit(yaw: Float, pitch: Float) {
        let at = Framing.shelf.at
        let base = Framing.shelf.from - at
        let qPitch = simd_quatf(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
        let qYaw = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        let offset = qYaw.act(qPitch.act(base))
        camera.look(at: at, from: at + offset, relativeTo: root)
    }

    /// Smoothly dollies the camera to a framing (scene transition).
    func animate(to framing: Framing, duration: TimeInterval = 0.7) {
        let target = Self.lookTransform(at: framing.at, from: framing.from)
        camera.move(to: target, relativeTo: root, duration: duration, timingFunction: .easeInOut)
    }

    /// Camera local transform that looks at `at` from `from` (camera faces its
    /// own -z), matching `Entity.look`.
    nonisolated static func lookTransform(
        at: SIMD3<Float>, from: SIMD3<Float>, up: SIMD3<Float> = SIMD3<Float>(0, 1, 0)
    ) -> Transform {
        let forward = simd_normalize(at - from)
        let z = -forward
        var x = simd_cross(up, z)
        if simd_length(x) < 1e-5 { x = simd_cross(SIMD3<Float>(1, 0, 0), z) }
        x = simd_normalize(x)
        let y = simd_cross(z, x)
        return Transform(scale: .one, rotation: simd_quatf(simd_float3x3(x, y, z)), translation: from)
    }

    /// World-space picking ray through a screen point.
    func ray(through screenPoint: CGPoint, viewport: CGSize) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        Self.ray(
            through: screenPoint,
            viewport: viewport,
            cameraTransform: camera.transformMatrix(relativeTo: nil),
            fovDegrees: fovDegrees
        )
    }

    /// Pure unprojection math. `cameraTransform` is the camera's world matrix;
    /// the camera looks down its local -z with the given *vertical* fov, and
    /// the horizontal fov follows from the viewport aspect ratio.
    nonisolated static func ray(
        through screenPoint: CGPoint,
        viewport: CGSize,
        cameraTransform: simd_float4x4,
        fovDegrees: Float
    ) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        precondition(viewport.width > 0 && viewport.height > 0, "viewport must be non-empty")
        let ndcX = Float(screenPoint.x / viewport.width) * 2 - 1
        let ndcY = 1 - Float(screenPoint.y / viewport.height) * 2
        let tanHalfFov = tan(fovDegrees * .pi / 360)
        let aspect = Float(viewport.width / viewport.height)

        let directionCamera = SIMD3<Float>(
            ndcX * tanHalfFov * aspect,
            ndcY * tanHalfFov,
            -1
        )

        let rotation = simd_float3x3(
            SIMD3<Float>(cameraTransform.columns.0.x, cameraTransform.columns.0.y, cameraTransform.columns.0.z),
            SIMD3<Float>(cameraTransform.columns.1.x, cameraTransform.columns.1.y, cameraTransform.columns.1.z),
            SIMD3<Float>(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
        )
        let origin = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        return (origin, simd_normalize(rotation * directionCamera))
    }
}
