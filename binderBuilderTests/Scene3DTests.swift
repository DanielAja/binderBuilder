//
//  Scene3DTests.swift
//  binderBuilderTests
//
//  Unit tests for the Scene3D math: CurlFunction (CPU twin of the
//  PageCurl.metal geometry modifier) and CameraRig ray unprojection.
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
