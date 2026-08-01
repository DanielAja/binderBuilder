//
//  GestureRouter.swift
//  binderBuilder
//
//  Routes the RealityView's DragGesture into page flips:
//  touch-down -> camera ray -> hit test -> classify (right page drags flip
//  forward, left page drags flip backward) -> drag x-displacement maps to
//  curl progress t -> release springs to 0/1 based on position + flick.
//
//  All the mapping math lives in nonisolated GestureMath so it is
//  unit-testable without a scene (GestureMathTests).
//

import CoreGraphics
import simd

// MARK: - Pure math

nonisolated enum GestureMath {
    /// Fraction of the viewport width a finger travels for a full flip.
    static let spanFraction: CGFloat = 0.55
    /// Maximum curl-axis tilt from grabbing a page corner (~25 degrees).
    static let maxGesturePsi: Float = 0.4363
    /// Physical finger speed (points/s) at or above which a release is a
    /// flick. Progress velocity is span-relative, so a fixed t-units/s
    /// threshold would mean "flick" at a different real-world hand speed on
    /// every screen size — easy on a phone, nearly unreachable on an iPad.
    /// The number is the old 1.8 t/s expressed at `referenceSpan`, so phone
    /// feel is unchanged and every other device now matches it.
    static let flickPointsPerSecond: CGFloat = 432
    /// The span the t-unit constants were originally tuned against
    /// (a ~436 pt viewport).
    static let referenceSpan: CGFloat = 240
    /// Clamp on the spring's initial velocity (t-units/s). Bounds how short
    /// the release animation can get, however hard the flick.
    static let maxSpringVelocity: Float = 6
    /// How far ahead (s) a sub-flick release's velocity is projected when
    /// picking the resting end, so a page that is still travelling commits to
    /// where it was heading instead of to where the finger happened to lift.
    static let releaseProjection: Float = 0.12

    static func span(viewportWidth: CGFloat) -> CGFloat {
        max(1, viewportWidth * spanFraction)
    }

    /// Flick threshold in t-units/s for a given span — the span-relative
    /// speed that corresponds to `flickPointsPerSecond` of finger travel.
    static func flickThreshold(span: CGFloat) -> Float {
        Float(flickPointsPerSecond / max(1, span))
    }

    /// Maps the drag's x translation to curl progress. Dragging LEFT (toward
    /// the spine) increases t for both directions: a forward flip starts at
    /// t = 0 and is dragged left; a backward flip starts at t = 1 and is
    /// dragged right (negative contribution).
    static func dragProgress(translationX: CGFloat, span: CGFloat, startT: Float) -> Float {
        let t = startT - Float(translationX / span)
        return min(max(t, 0), 1)
    }

    /// Drag velocity in t-units/s (positive = toward t = 1).
    static func progressVelocity(velocityX: CGFloat, span: CGFloat) -> Float {
        -Float(velocityX / span)
    }

    /// Where the page springs on release: a flick wins regardless of
    /// position; otherwise the page falls to the nearer rest pose *as
    /// projected forward by its release velocity*, so a page released just
    /// short of the midpoint but still moving over keeps going instead of
    /// reversing under the finger.
    static func releaseTarget(
        t: Float,
        velocity: Float,
        flickThreshold: Float = GestureMath.flickThreshold(span: GestureMath.referenceSpan)
    ) -> Float {
        if abs(velocity) >= flickThreshold {
            return velocity > 0 ? 1 : 0
        }
        return t + velocity * releaseProjection > 0.5 ? 1 : 0
    }

    /// Curl-axis tilt from where the page was grabbed along its height:
    /// 0 at the vertical center, up to ±maxGesturePsi at the corners.
    /// `heightFraction`: 0 = bottom (near) edge, 1 = top (far) edge.
    static func cornerPsi(heightFraction: Float) -> Float {
        let normalized = min(max(heightFraction, 0), 1) * 2 - 1
        return normalized * maxGesturePsi
    }

    /// Ray vs oriented bounding box (slab test in the box's local frame).
    /// Returns the distance along the (unit) direction to the nearest
    /// intersection at or in front of the origin, or nil on a miss.
    static func rayOBBIntersection(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        obb: OBB
    ) -> Float? {
        let inverse = obb.orientation.inverse
        let localOrigin = inverse.act(origin - obb.center)
        let localDirection = inverse.act(direction)

        var tMin: Float = -.greatestFiniteMagnitude
        var tMax: Float = .greatestFiniteMagnitude
        for axis in 0..<3 {
            let o = localOrigin[axis]
            let d = localDirection[axis]
            let h = obb.halfExtents[axis]
            if abs(d) < 1e-8 {
                if abs(o) > h { return nil }
                continue
            }
            var t0 = (-h - o) / d
            var t1 = (h - o) / d
            if t0 > t1 { swap(&t0, &t1) }
            tMin = max(tMin, t0)
            tMax = min(tMax, t1)
            if tMin > tMax { return nil }
        }
        if tMax < 0 { return nil }
        return tMin >= 0 ? tMin : tMax
    }
}

// MARK: - Router

import RealityKit
import SwiftUI

/// Lifecycle of one drag, fed by the SwiftUI DragGesture callbacks.
@MainActor
final class GestureRouter {
    enum FlipDirection {
        case forward
        case backward
    }

    private enum State {
        case idle
        /// Touch landed somewhere unflippable — swallow the rest of the drag.
        case rejected
        /// `slopX` is the translation already accumulated when the gesture
        /// recognized (DragGesture's minimumDistance). Subtracting it keeps
        /// the page glued to the finger: without it the page jumps by the
        /// recognizer's slop the instant the drag is handed to us.
        case tracking(direction: FlipDirection, startT: Float, psi: Float, span: CGFloat, slopX: CGFloat)
    }

    private let controller: BinderFlipController
    private let hitTester: any HitTesting
    private let cameraRig: CameraRig
    private var state: State = .idle

    init(controller: BinderFlipController, hitTester: any HitTesting, cameraRig: CameraRig) {
        self.controller = controller
        self.hitTester = hitTester
        self.cameraRig = cameraRig
    }

    func dragChanged(location: CGPoint, startLocation: CGPoint, translation: CGSize, viewport: CGSize) {
        if case .idle = state {
            begin(at: startLocation, slopX: translation.width, viewport: viewport)
        }
        guard case .tracking(_, let startT, let psi, let span, let slopX) = state else { return }
        let t = GestureMath.dragProgress(
            translationX: translation.width - slopX, span: span, startT: startT
        )
        controller.updateDrag(t: t, psi: psi)
    }

    func dragEnded(translation: CGSize, velocity: CGSize, viewport: CGSize) {
        defer { state = .idle }
        guard case .tracking(_, let startT, _, let span, let slopX) = state else { return }
        let t = GestureMath.dragProgress(
            translationX: translation.width - slopX, span: span, startT: startT
        )
        let velocityT = GestureMath.progressVelocity(velocityX: velocity.width, span: span)
        controller.endDrag(
            t: t, velocity: velocityT, flickThreshold: GestureMath.flickThreshold(span: span)
        )
    }

    private func begin(at point: CGPoint, slopX: CGFloat, viewport: CGSize) {
        guard viewport.width > 0, viewport.height > 0 else {
            state = .rejected
            return
        }
        let ray = cameraRig.ray(through: point, viewport: viewport)
        guard let hit = hitTester.hitTest(origin: ray.origin, direction: ray.direction) else {
            state = .rejected
            return
        }

        let direction: FlipDirection
        switch hit.kind {
        case .rightPage: direction = .forward
        case .leftPage: direction = .backward
        case .leftCover, .rightCover:
            // Covers are reserved for the shelf transition (later phase).
            state = .rejected
            return
        }

        // Touch height up the page (world -z is "up the page"): 0 at the
        // near/bottom edge, 1 at the far/top edge.
        let heightFraction = (PageFactory.pageOriginZ - hit.worldPoint.z) / BinderBuilder3D.pageStackDepth
        let psi = GestureMath.cornerPsi(heightFraction: heightFraction)

        guard let startT = controller.beginDrag(direction: direction, psi: psi) else {
            state = .rejected
            return
        }
        state = .tracking(
            direction: direction,
            startT: startT,
            psi: psi,
            span: GestureMath.span(viewportWidth: viewport.width),
            slopX: slopX
        )
    }
}
