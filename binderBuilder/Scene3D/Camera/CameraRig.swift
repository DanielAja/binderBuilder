//
//  CameraRig.swift
//  binderBuilder
//
//  Owns the virtual PerspectiveCamera on a rig parent entity, provides
//  framing presets, and unprojects screen points into world-space rays
//  (used by gesture picking in later phases). The ray math is a pure
//  nonisolated static function so it is unit-testable without a scene.
//
//  Framings are aspect-aware: each preset carries a look direction plus the
//  half-width of the content that must stay on screen, and the camera
//  distance is re-solved for the live viewport aspect (see
//  `framingDistance`), so a narrow phone doesn't clip the binder and an iPad
//  portrait doesn't strand it in the middle of the screen.
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
    /// Viewport aspect (width / height) the current framing is solved for.
    /// Stays at the tuning aspect until a view reports its size, so rigs with
    /// no view attached (tests, debug scenes) keep the reference framing.
    private(set) var aspect: Float = Framing.tunedAspect
    /// Framing currently applied; re-solved when the viewport aspect changes.
    private(set) var framing: Framing = .binderOpen
    /// Last shelf orbit committed by `setShelfOrbit`, so a resize can keep it.
    private var shelfOrbit: (yaw: Float, pitch: Float) = (0, 0)

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
    ///
    /// `at`/`from` were tuned on the reference device (iPhone 16 Pro Max
    /// portrait, aspect `tunedAspect`). Only the *direction* from `at` toward
    /// `from` is fixed; the distance along it is re-solved per viewport from
    /// `subjectHalfWidth` — see `CameraRig.framingDistance`.
    enum Framing {
        /// Open binder lying at the origin.
        case binderOpen
        /// Shelf with the standing binder + display cases (binder ~1 m away).
        case shelf

        /// Viewport aspect the `from` constants were tuned against.
        static let tunedAspect: Float = 0.543

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

        /// Half-width (m) of the content that must stay inside the frame.
        /// - binderOpen: the open binder spans +-0.265 (two 0.26 covers
        ///   straddling a 0.01 spine gap — BinderBuilder3D.coverWidth).
        /// - shelf: the three display cases reach +-0.385; 0.45 keeps a slice
        ///   of slab beyond them and reproduces the tuned distance to ~1%.
        var subjectHalfWidth: Float {
            switch self {
            case .binderOpen: return 0.265
            case .shelf: return 0.45
            }
        }

        /// Distance from `at` to `from` as tuned on the reference device; the
        /// solved distance is clamped relative to it.
        var tunedDistance: Float { simd_length(from - at) }

        /// Unit vector pointing from the subject toward the camera.
        var eyeDirection: SIMD3<Float> { simd_normalize(from - at) }
    }

    /// Breathing room kept on each side of the subject, as a fraction of its
    /// half-width (8% per side, i.e. the subject fills ~93% of the frame).
    nonisolated static let marginFraction: Float = 0.08

    /// How far the solved distance may stray from a framing's tuned distance.
    /// The floor keeps very wide viewports (iPad portrait, landscape) from
    /// diving into the geometry; the ceiling keeps very narrow ones from
    /// shrinking the subject to a speck. At the tuning aspect neither binds.
    nonisolated static let distanceClamp: ClosedRange<Float> = 0.75...1.8

    /// Frames the open binder (lying at the origin, ~0.53 m wide) in portrait:
    /// camera above and in front, looking down at ~52 degrees.
    func applyBinderOpenFraming() {
        apply(.binderOpen)
    }

    /// Snaps the camera to a framing immediately.
    func apply(_ framing: Framing) {
        self.framing = framing
        camera.look(at: framing.at, from: eye(for: framing), relativeTo: root)
    }

    /// Orbits the shelf framing by yaw (around world up) and pitch (around the
    /// camera's right axis), keeping the shelf focus centered. Used by the
    /// shelf pan gesture.
    func setShelfOrbit(yaw: Float, pitch: Float) {
        framing = .shelf
        shelfOrbit = (yaw, pitch)
        let at = Framing.shelf.at
        let base = eye(for: .shelf) - at
        let qPitch = simd_quatf(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
        let qYaw = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        let offset = qYaw.act(qPitch.act(base))
        camera.look(at: at, from: at + offset, relativeTo: root)
    }

    /// Smoothly dollies the camera to a framing (scene transition).
    func animate(to framing: Framing, duration: TimeInterval = 0.7) {
        self.framing = framing
        let target = Self.lookTransform(at: framing.at, from: eye(for: framing))
        camera.move(to: target, relativeTo: root, duration: duration, timingFunction: .easeInOut)
    }

    // MARK: Aspect-aware framing

    /// Reports the live viewport so the current framing can be re-solved for
    /// its aspect. Call it on first layout with `animated: false` (the scene
    /// should simply appear correctly framed) and on later size changes —
    /// rotation, iPad multitasking — with `animated: true` so the dolly reads
    /// as deliberate. A shelf orbit in progress is preserved.
    func setViewport(_ size: CGSize, animated: Bool) {
        guard size.width > 0, size.height > 0 else { return }
        let newAspect = Float(size.width / size.height)
        guard newAspect.isFinite, abs(newAspect - aspect) > 1e-4 else { return }
        aspect = newAspect

        if framing == .shelf, shelfOrbit.yaw != 0 || shelfOrbit.pitch != 0 {
            setShelfOrbit(yaw: shelfOrbit.yaw, pitch: shelfOrbit.pitch)
        } else if animated {
            animate(to: framing, duration: 0.3)
        } else {
            apply(framing)
        }
    }

    /// Eye position for a framing at the current viewport aspect: the tuned
    /// direction, with the distance solved for the visible width.
    func eye(for framing: Framing) -> SIMD3<Float> {
        let distance = Self.framingDistance(
            subjectHalfWidth: framing.subjectHalfWidth,
            tunedDistance: framing.tunedDistance,
            aspect: aspect,
            fovDegrees: fovDegrees
        )
        return framing.at + framing.eyeDirection * distance
    }

    /// Camera distance that fits a subject of half-width `subjectHalfWidth`
    /// (plus `marginFraction` of it as margin on each side) across the frame's
    /// VISIBLE WIDTH. With a vertical fov, that width grows with the aspect:
    ///
    ///     visibleWidth = 2 * d * tan(fov / 2) * aspect
    ///
    /// so the distance that just contains the subject plus its margins is
    ///
    ///     d = subjectHalfWidth * (1 + marginFraction) / (tan(fov / 2) * aspect)
    ///
    /// The result is clamped to `distanceClamp` x `tunedDistance` so a
    /// pathological aspect can neither push the camera through the subject nor
    /// strand it in the distance; at the tuning aspect the solve lands within
    /// a few percent of the tuned distance, which is what keeps the reference
    /// device's look unchanged.
    nonisolated static func framingDistance(
        subjectHalfWidth: Float,
        tunedDistance: Float,
        aspect: Float,
        fovDegrees: Float
    ) -> Float {
        precondition(subjectHalfWidth > 0 && tunedDistance > 0 && aspect > 0, "framing inputs must be positive")
        let required = subjectHalfWidth * (1 + marginFraction) / (tan(fovDegrees * .pi / 360) * aspect)
        return min(
            max(required, tunedDistance * distanceClamp.lowerBound),
            tunedDistance * distanceClamp.upperBound
        )
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
