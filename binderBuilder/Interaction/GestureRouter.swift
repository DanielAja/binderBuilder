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
    /// Release velocities (t-units/s) above this count as a flick.
    static let flickThreshold: Float = 1.8
    /// Clamp on the spring's initial velocity (t-units/s).
    static let maxSpringVelocity: Float = 6

    static func span(viewportWidth: CGFloat) -> CGFloat {
        max(1, viewportWidth * spanFraction)
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
    /// position; otherwise the page falls to the nearer rest pose.
    static func releaseTarget(
        t: Float,
        velocity: Float,
        flickThreshold: Float = GestureMath.flickThreshold
    ) -> Float {
        if abs(velocity) >= flickThreshold {
            return velocity > 0 ? 1 : 0
        }
        return t > 0.5 ? 1 : 0
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
        case tracking(direction: FlipDirection, startT: Float, psi: Float, span: CGFloat)
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
            begin(at: startLocation, viewport: viewport)
        }
        guard case .tracking(_, let startT, let psi, let span) = state else { return }
        let t = GestureMath.dragProgress(translationX: translation.width, span: span, startT: startT)
        controller.updateDrag(t: t, psi: psi)
    }

    func dragEnded(translation: CGSize, velocity: CGSize, viewport: CGSize) {
        defer { state = .idle }
        guard case .tracking(_, let startT, _, let span) = state else { return }
        let t = GestureMath.dragProgress(translationX: translation.width, span: span, startT: startT)
        let velocityT = GestureMath.progressVelocity(velocityX: velocity.width, span: span)
        controller.endDrag(t: t, velocity: velocityT)
    }

    private func begin(at point: CGPoint, viewport: CGSize) {
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
            span: GestureMath.span(viewportWidth: viewport.width)
        )
    }
}
