//
//  Scene3DTests.swift
//  binderBuilderTests
//
//  Unit tests for the Scene3D math: CurlFunction (CPU twin of the
//  PageCurl.metal geometry modifier), CameraRig ray unprojection, and the
//  aspect-aware framing solve.
//

import CoreGraphics
import Testing
import simd
@testable import binderBuilder

struct CurlFunctionTests {
    private let accuracy: Float = 1e-5

    @Test func flatWhenCurlDistanceAtOrBeyondPageWidth() {
        let params = CurlParams(d: PageMesh.width, r: 0.05, psi: 0)
        for x in stride(from: Float(0), through: PageMesh.width, by: PageMesh.width / 8) {
            for y in stride(from: Float(0), through: PageMesh.height, by: PageMesh.height / 6) {
                let p = SIMD3<Float>(x, y, 0)
                let out = CurlFunction.deform(position: p, normal: SIMD3<Float>(0, 0, 1), params: params)
                #expect(simd_length(out.position - p) < accuracy)
                #expect(simd_length(out.normal - SIMD3<Float>(0, 0, 1)) < accuracy)
            }
        }
        // Even farther than the page width.
        let far = CurlParams(d: PageMesh.width * 2, r: 0.03, psi: 0.4)
        let p = SIMD3<Float>(PageMesh.width, PageMesh.height, 0)
        let out = CurlFunction.deform(position: p, normal: SIMD3<Float>(0, 0, 1), params: far)
        #expect(simd_length(out.position - p) < accuracy)
    }

    @Test func quarterTurnVertexLiftsToRadius() {
        // Vertex at x = d + pi*r/2 sits a quarter-turn up the cylinder: z == r.
        let d: Float = 0.06
        let r: Float = 0.05
        let params = CurlParams(d: d, r: r, psi: 0)
        let x = d + .pi * r / 2
        let out = CurlFunction.deform(
            position: SIMD3<Float>(x, 0.1, 0),
            normal: SIMD3<Float>(0, 0, 1),
            params: params
        )
        #expect(abs(out.position.z - r) < accuracy)
        // Quarter turn: surface x is d + r (sin(pi/2) == 1), y unchanged.
        #expect(abs(out.position.x - (d + r)) < accuracy)
        #expect(abs(out.position.y - 0.1) < accuracy)
        // Normal has rotated 90 degrees: from +z to -x.
        #expect(simd_length(out.normal - SIMD3<Float>(-1, 0, 0)) < 1e-4)
    }

    @Test func halfTurnVertexReachesTopOfCylinder() {
        // Vertex at x = d + pi*r folds fully over: z == 2r, normal flipped.
        let d: Float = 0.05
        let r: Float = 0.04
        let params = CurlParams(d: d, r: r, psi: 0)
        let out = CurlFunction.deform(
            position: SIMD3<Float>(d + .pi * r, 0.2, 0),
            normal: SIMD3<Float>(0, 0, 1),
            params: params
        )
        #expect(abs(out.position.z - 2 * r) < accuracy)
        #expect(simd_length(out.normal - SIMD3<Float>(0, 0, -1)) < 1e-4)
    }

    @Test func beyondHalfTurnMaterialHeadsBackTowardSpine() {
        // Past the top of the cylinder the page lies flat upside-down,
        // marching back toward the spine as x grows.
        let d: Float = 0.02
        let r: Float = 0.03
        let params = CurlParams(d: d, r: r, psi: 0)
        let overshoot: Float = 0.05
        let out = CurlFunction.deform(
            position: SIMD3<Float>(d + .pi * r + overshoot, 0, 0),
            normal: SIMD3<Float>(0, 0, 1),
            params: params
        )
        #expect(abs(out.position.x - (d - overshoot)) < accuracy)
        #expect(abs(out.position.z - 2 * r) < accuracy)
    }

    @Test func normalsStayUnitLength() {
        let params = CurlParams(d: 0.07, r: 0.045, psi: 0.3)
        for x in stride(from: Float(0), through: PageMesh.width, by: PageMesh.width / 16) {
            for y in stride(from: Float(0), through: PageMesh.height, by: PageMesh.height / 10) {
                for n in [SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, 0, -1)] {
                    let out = CurlFunction.deform(position: SIMD3<Float>(x, y, 0), normal: n, params: params)
                    #expect(abs(simd_length(out.normal) - 1) < 1e-4)
                }
            }
        }
    }

    @Test func psiTiltsTheCurlAxis() {
        // With psi != 0 the curl line x' == d is tilted: two vertices with the
        // same x but different y deform differently.
        let params = CurlParams(d: 0.1, r: 0.05, psi: 0.4)
        let a = CurlFunction.deform(position: SIMD3<Float>(0.12, 0.02, 0), normal: SIMD3<Float>(0, 0, 1), params: params)
        let b = CurlFunction.deform(position: SIMD3<Float>(0.12, 0.28, 0), normal: SIMD3<Float>(0, 0, 1), params: params)
        #expect(abs(a.position.z - b.position.z) > 1e-3)
        // And a vertex on the spine side of the tilted line stays put.
        let c = CurlFunction.deform(position: SIMD3<Float>(0.02, 0.02, 0), normal: SIMD3<Float>(0, 0, 1), params: params)
        #expect(simd_length(c.position - SIMD3<Float>(0.02, 0.02, 0)) < accuracy)
    }

    @Test func progressZeroIsFlatAcrossWholePage() {
        let params = CurlParams.progress(0)
        #expect(params.d == PageMesh.width)
        #expect(params.psi == 0)
        let corner = SIMD3<Float>(PageMesh.width, PageMesh.height, 0)
        let out = CurlFunction.deform(position: corner, normal: SIMD3<Float>(0, 0, 1), params: params)
        #expect(simd_length(out.position - corner) < accuracy)
    }
}

struct CameraRayTests {
    private let viewport = CGSize(width: 390, height: 844)

    @Test func centerRayPointsDownCameraForward() {
        let ray = CameraRig.ray(
            through: CGPoint(x: viewport.width / 2, y: viewport.height / 2),
            viewport: viewport,
            cameraTransform: matrix_identity_float4x4,
            fovDegrees: 60
        )
        #expect(simd_length(ray.origin) < 1e-6)
        #expect(simd_length(ray.direction - SIMD3<Float>(0, 0, -1)) < 1e-5)
    }

    @Test func topCenterRayMatchesVerticalFov() {
        let fov: Float = 60
        let ray = CameraRig.ray(
            through: CGPoint(x: viewport.width / 2, y: 0),
            viewport: viewport,
            cameraTransform: matrix_identity_float4x4,
            fovDegrees: fov
        )
        // Angle from forward equals half the vertical fov.
        let cosAngle = simd_dot(ray.direction, SIMD3<Float>(0, 0, -1))
        #expect(abs(cosAngle - cos(fov / 2 * .pi / 180)) < 1e-5)
        #expect(ray.direction.y > 0)
        #expect(abs(ray.direction.x) < 1e-6)
    }

    @Test func rightEdgeRayMatchesHorizontalFov() {
        let fov: Float = 55
        let ray = CameraRig.ray(
            through: CGPoint(x: viewport.width, y: viewport.height / 2),
            viewport: viewport,
            cameraTransform: matrix_identity_float4x4,
            fovDegrees: fov
        )
        let tanHalfH = tan(fov / 2 * .pi / 180) * Float(viewport.width / viewport.height)
        let expected = simd_normalize(SIMD3<Float>(tanHalfH, 0, -1))
        #expect(simd_length(ray.direction - expected) < 1e-5)
    }

    @Test func translatedCameraMovesRayOrigin() {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(0.3, 1.2, -0.5, 1)
        let ray = CameraRig.ray(
            through: CGPoint(x: viewport.width / 2, y: viewport.height / 2),
            viewport: viewport,
            cameraTransform: transform,
            fovDegrees: 50
        )
        #expect(simd_length(ray.origin - SIMD3<Float>(0.3, 1.2, -0.5)) < 1e-6)
        #expect(simd_length(ray.direction - SIMD3<Float>(0, 0, -1)) < 1e-5)
    }

    @Test func rotatedCameraRotatesRayDirection() {
        // Camera yawed 90 degrees left (+y axis): forward (-z) becomes -x.
        let q = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        var transform = simd_float4x4(q)
        transform.columns.3 = SIMD4<Float>(0, 0, 0, 1)
        let ray = CameraRig.ray(
            through: CGPoint(x: viewport.width / 2, y: viewport.height / 2),
            viewport: viewport,
            cameraTransform: transform,
            fovDegrees: 60
        )
        #expect(simd_length(ray.direction - SIMD3<Float>(-1, 0, 0)) < 1e-5)
    }

    @Test func directionIsAlwaysUnitLength() {
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 390, y: 844), CGPoint(x: 17, y: 600)] {
            let ray = CameraRig.ray(
                through: point,
                viewport: viewport,
                cameraTransform: matrix_identity_float4x4,
                fovDegrees: 47
            )
            #expect(abs(simd_length(ray.direction) - 1) < 1e-5)
        }
    }
}

/// `RecentAdditions` (CardFloatSystem) + `firstFloatGlint` (MotionUpdateSystem):
/// the "first touch" glint bump a newly-added card gets the first time it
/// floats — fires exactly once per marked cardID, then clears.
struct FirstFloatGlintTests {
    @Test func recentAdditionsConsumeFiresOnceThenClears() {
        let registry = RecentAdditions.shared
        registry.mark(cardID: "test-glint-card")
        #expect(registry.consume(cardID: "test-glint-card") == true)
        // Already claimed: a second float of the same card doesn't re-glint.
        #expect(registry.consume(cardID: "test-glint-card") == false)
        // Never marked: no-op, not a crash.
        #expect(registry.consume(cardID: "never-marked-card") == false)
    }

    @Test func firstFloatGlintEnvelopeStartsHighThenEndsAtZero() {
        // Bigger than the ordinary ambient shimmer at the same progress.
        let bumped = MotionUpdateSystem.firstFloatGlint(progress: MotionUpdateSystem.shimmerDuration / 2)
        let ordinary = MotionUpdateSystem.shimmerSweep(elapsed: MotionUpdateSystem.shimmerDuration / 2)
        #expect(bumped > ordinary)
        #expect(bumped > 0)
        // Spent once elapsed reaches the bump duration — the caller then
        // clears CardFloatComponent.firstTouchGlint so it never repeats.
        #expect(MotionUpdateSystem.firstFloatGlint(progress: MotionUpdateSystem.shimmerDuration) == 0)
        #expect(MotionUpdateSystem.firstFloatGlint(progress: MotionUpdateSystem.shimmerDuration + 1) == 0)
    }
}

@MainActor
struct CameraFramingTests {
    private let fov: Float = 55
    /// iPhone SE-class portrait (wider frame than the tuning device).
    private let seAspect: Float = 0.627
    /// iPad portrait — much wider, and the worst case before this solve.
    private let padAspect: Float = 0.81

    /// World width visible at `distance` for a vertical `fov`.
    private func visibleWidth(distance: Float, aspect: Float) -> Float {
        2 * distance * tan(fov * .pi / 360) * aspect
    }

    private func distance(_ framing: CameraRig.Framing, aspect: Float) -> Float {
        CameraRig.framingDistance(
            subjectHalfWidth: framing.subjectHalfWidth,
            tunedDistance: framing.tunedDistance,
            aspect: aspect,
            fovDegrees: fov
        )
    }

    @Test func tuningAspectReproducesTheTunedDistance() {
        // Regression anchor: the reference device's look must not move.
        for framing in [CameraRig.Framing.binderOpen, .shelf] {
            let solved = distance(framing, aspect: CameraRig.Framing.tunedAspect)
            #expect(abs(solved - framing.tunedDistance) / framing.tunedDistance < 0.05)
        }
    }

    @Test func binderNeverClipsAcrossPortraitAspects() {
        let framing = CameraRig.Framing.binderOpen
        let subject = 2 * framing.subjectHalfWidth
        for aspect in [Float(0.40), 0.45, 0.50, 0.543, 0.627, 0.70, 0.81, 0.90] {
            let width = visibleWidth(distance: distance(framing, aspect: aspect), aspect: aspect)
            // Subject plus a margin on each side always fits.
            #expect(width >= subject * (1 + CameraRig.marginFraction) - 1e-4)
        }
    }

    @Test func sePortraitPullsInAndKeepsTheMargin() {
        let framing = CameraRig.Framing.binderOpen
        let solved = distance(framing, aspect: seAspect)
        // Wider frame than the tuning device -> camera comes closer.
        #expect(solved < framing.tunedDistance)
        // ...but only as close as the margin allows: fill is the fixed ~93%.
        let fill = 2 * framing.subjectHalfWidth / visibleWidth(distance: solved, aspect: seAspect)
        #expect(abs(fill - 1 / (1 + CameraRig.marginFraction)) < 1e-3)
    }

    @Test func iPadPortraitFillsFarMoreOfTheFrame() {
        let framing = CameraRig.Framing.binderOpen
        let solved = distance(framing, aspect: padAspect)
        // The floor of the clamp binds here (a free solve would come closer).
        #expect(abs(solved - framing.tunedDistance * CameraRig.distanceClamp.lowerBound) < 1e-4)
        let fill = 2 * framing.subjectHalfWidth / visibleWidth(distance: solved, aspect: padAspect)
        let tunedFill = 2 * framing.subjectHalfWidth
            / visibleWidth(distance: framing.tunedDistance, aspect: padAspect)
        #expect(tunedFill < 0.70) // the bug: binder stranded mid-screen
        #expect(fill > 0.80)
    }

    @Test func shelfKeepsTheDisplayCasesOnScreen() {
        let framing = CameraRig.Framing.shelf
        // Outer edge of the outer display case (slot at 0.34, case 0.09 wide).
        let contentHalfWidth: Float = 0.385
        for aspect in [Float(0.45), 0.543, seAspect, padAspect] {
            let width = visibleWidth(distance: distance(framing, aspect: aspect), aspect: aspect)
            #expect(width / 2 > contentHalfWidth)
        }
        // And the shelf comes closer on wider frames, as the binder does.
        #expect(distance(framing, aspect: padAspect) < distance(framing, aspect: seAspect))
        #expect(distance(framing, aspect: seAspect) < framing.tunedDistance)
    }

    @Test func extremeAspectsHitTheClamps() {
        let framing = CameraRig.Framing.binderOpen
        let tuned = framing.tunedDistance
        // Absurdly narrow: capped so the binder can't recede forever.
        #expect(abs(distance(framing, aspect: 0.2) - tuned * CameraRig.distanceClamp.upperBound) < 1e-4)
        // Landscape: floored so the camera can't dive into the geometry.
        #expect(abs(distance(framing, aspect: 2.16) - tuned * CameraRig.distanceClamp.lowerBound) < 1e-4)
    }

    @Test func distanceVariesInverselyWithAspectInsideTheClamps() {
        let framing = CameraRig.Framing.shelf
        let wide = distance(framing, aspect: 0.7)
        let narrow = distance(framing, aspect: 0.35)
        #expect(abs(narrow - 2 * wide) < 1e-3)
    }
}
