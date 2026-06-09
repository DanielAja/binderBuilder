//
//  GestureMathTests.swift
//  binderBuilderTests
//
//  Unit tests for the drag -> curl mapping (GestureMath): progress from
//  x-displacement, release targets incl. flick override, corner psi, and
//  the analytic ray/OBB intersection used by the fallback hit tester.
//

import CoreGraphics
import Testing
import simd
@testable import binderBuilder

struct DragMappingTests {
    private let span: CGFloat = 240

    @Test func forwardDragLeftIncreasesProgress() {
        // Forward flips start at t = 0; dragging LEFT (negative x) curls.
        #expect(GestureMath.dragProgress(translationX: 0, span: span, startT: 0) == 0)
        #expect(abs(GestureMath.dragProgress(translationX: -120, span: span, startT: 0) - 0.5) < 1e-5)
        #expect(GestureMath.dragProgress(translationX: -240, span: span, startT: 0) == 1)
        // Clamped past a full flip.
        #expect(GestureMath.dragProgress(translationX: -500, span: span, startT: 0) == 1)
        // Dragging the wrong way does nothing.
        #expect(GestureMath.dragProgress(translationX: 100, span: span, startT: 0) == 0)
    }

    @Test func backwardDragRightDecreasesProgress() {
        // Backward flips grab the left page at t = 1 and drag RIGHT.
        #expect(abs(GestureMath.dragProgress(translationX: 120, span: span, startT: 1) - 0.5) < 1e-5)
        #expect(GestureMath.dragProgress(translationX: 240, span: span, startT: 1) == 0)
        #expect(GestureMath.dragProgress(translationX: 999, span: span, startT: 1) == 0)
    }

    @Test func regrabbingASpringingPageResumesFromItsLiveT() {
        #expect(abs(GestureMath.dragProgress(translationX: -60, span: span, startT: 0.4) - 0.65) < 1e-5)
    }

    @Test func velocityConversionPointsTowardProgress() {
        // Leftward finger velocity = positive t-velocity (toward t = 1).
        #expect(GestureMath.progressVelocity(velocityX: -480, span: span) == 2)
        #expect(GestureMath.progressVelocity(velocityX: 480, span: span) == -2)
    }

    @Test func spanIsAFractionOfTheViewport() {
        #expect(GestureMath.span(viewportWidth: 400) == 400 * GestureMath.spanFraction)
        #expect(GestureMath.span(viewportWidth: 0) == 1) // never divides by zero
    }
}

struct ReleaseTargetTests {
    @Test func slowReleasesFallToTheNearerSide() {
        #expect(GestureMath.releaseTarget(t: 0.49, velocity: 0) == 0)
        #expect(GestureMath.releaseTarget(t: 0.51, velocity: 0) == 1)
        #expect(GestureMath.releaseTarget(t: 0.2, velocity: 0.5) == 0)
        #expect(GestureMath.releaseTarget(t: 0.9, velocity: -0.5) == 1)
    }

    @Test func flicksOverridePosition() {
        // Barely-started page + hard leftward flick: completes the flip.
        #expect(GestureMath.releaseTarget(t: 0.15, velocity: 2.5) == 1)
        // Mostly-flipped page + hard rightward flick: snaps back.
        #expect(GestureMath.releaseTarget(t: 0.85, velocity: -2.5) == 0)
        // Exactly at threshold counts as a flick.
        #expect(GestureMath.releaseTarget(t: 0.1, velocity: GestureMath.flickThreshold) == 1)
        // Just under threshold does not.
        #expect(GestureMath.releaseTarget(t: 0.1, velocity: GestureMath.flickThreshold - 0.01) == 0)
    }
}

struct CornerPsiTests {
    @Test func centerGrabIsFlatAndCornersTiltToTwentyFiveDegrees() {
        #expect(abs(GestureMath.cornerPsi(heightFraction: 0.5)) < 1e-6)
        let maxDegrees = GestureMath.maxGesturePsi * 180 / .pi
        #expect(abs(maxDegrees - 25) < 0.01)
        #expect(abs(GestureMath.cornerPsi(heightFraction: 1) - GestureMath.maxGesturePsi) < 1e-6)
        #expect(abs(GestureMath.cornerPsi(heightFraction: 0) + GestureMath.maxGesturePsi) < 1e-6)
    }

    @Test func outOfRangeFractionsClamp() {
        #expect(GestureMath.cornerPsi(heightFraction: 7) == GestureMath.maxGesturePsi)
        #expect(GestureMath.cornerPsi(heightFraction: -7) == -GestureMath.maxGesturePsi)
    }
}

struct RayOBBTests {
    @Test func verticalRayHitsAxisAlignedBox() {
        let obb = OBB(center: SIMD3<Float>(0.125, 0.02, 0), halfExtents: SIMD3<Float>(0.12, 0.003, 0.15))
        let distance = GestureMath.rayOBBIntersection(
            origin: SIMD3<Float>(0.125, 0.5, 0),
            direction: SIMD3<Float>(0, -1, 0),
            obb: obb
        )
        #expect(distance != nil)
        #expect(abs(distance! - (0.5 - 0.023)) < 1e-5)
    }

    @Test func missesBesideTheBox() {
        let obb = OBB(center: .zero, halfExtents: SIMD3<Float>(0.1, 0.01, 0.1))
        let distance = GestureMath.rayOBBIntersection(
            origin: SIMD3<Float>(0.5, 1, 0),
            direction: SIMD3<Float>(0, -1, 0),
            obb: obb
        )
        #expect(distance == nil)
    }

    @Test func missesBoxBehindTheRay() {
        let obb = OBB(center: SIMD3<Float>(0, -1, 0), halfExtents: SIMD3<Float>(0.1, 0.1, 0.1))
        let distance = GestureMath.rayOBBIntersection(
            origin: .zero,
            direction: SIMD3<Float>(0, 1, 0),
            obb: obb
        )
        #expect(distance == nil)
    }

    @Test func hitsRotatedBox() {
        // Box yawed 45 degrees: a ray down its rotated long axis still hits,
        // and a ray that would hit the unrotated extent misses.
        let yaw = simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 1, 0))
        let obb = OBB(center: .zero, halfExtents: SIMD3<Float>(0.2, 0.01, 0.02), orientation: yaw)
        // The +x tip rotates toward -z; sample a point above the rotated tip.
        let tip = yaw.act(SIMD3<Float>(0.19, 0, 0))
        let hit = GestureMath.rayOBBIntersection(
            origin: SIMD3<Float>(tip.x, 1, tip.z),
            direction: SIMD3<Float>(0, -1, 0),
            obb: obb
        )
        #expect(hit != nil)
        // The unrotated tip location no longer intersects.
        let miss = GestureMath.rayOBBIntersection(
            origin: SIMD3<Float>(0.19, 1, 0),
            direction: SIMD3<Float>(0, -1, 0),
            obb: obb
        )
        #expect(miss == nil)
    }

    @Test func rayStartingInsideReturnsExit() {
        let obb = OBB(center: .zero, halfExtents: SIMD3<Float>(1, 1, 1))
        let distance = GestureMath.rayOBBIntersection(
            origin: .zero,
            direction: SIMD3<Float>(0, 0, -1),
            obb: obb
        )
        #expect(distance != nil)
        #expect(abs(distance! - 1) < 1e-6)
    }
}
