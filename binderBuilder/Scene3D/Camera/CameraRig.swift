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

    /// Frames the open binder (lying at the origin, ~0.53 m wide) in portrait:
    /// camera above and in front, looking down at ~52 degrees.
    func applyBinderOpenFraming() {
        camera.look(
            at: SIMD3<Float>(0, 0.02, -0.02),
            from: SIMD3<Float>(0, 0.78, 0.60),
            relativeTo: root
        )
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
