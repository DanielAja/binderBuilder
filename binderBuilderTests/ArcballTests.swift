//
//  ArcballTests.swift
//  binderBuilderTests
//
//  Arcball projection/rotation math and the floating-card look basis.
//

import Testing
import CoreGraphics
import simd
@testable import binderBuilder

@Suite struct ArcballTests {
    private let viewport = CGSize(width: 400, height: 800)

    @Test func centerProjectsToPole() {
        let v = Arcball.project(point: CGPoint(x: 200, y: 400), viewport: viewport)
        #expect(abs(v.x) < 1e-5)
        #expect(abs(v.y) < 1e-5)
        #expect(abs(v.z - 1) < 1e-5)
    }

    @Test func projectionsAreUnitLength() {
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 400, y: 800), CGPoint(x: 380, y: 60)] {
            let v = Arcball.project(point: p, viewport: viewport)
            #expect(abs(length(v) - 1) < 1e-4)
        }
    }

    @Test func identityRotationForSamePoint() {
        let q = Arcball.rotation(from: SIMD3<Float>(0, 0, 1), to: SIMD3<Float>(0, 0, 1))
        #expect(abs(q.angle) < 1e-4)
    }

    @Test func rotationTakesFromToTo() {
        let from = SIMD3<Float>(1, 0, 0)
        let to = SIMD3<Float>(0, 1, 0)
        let q = Arcball.rotation(from: from, to: to)
        let rotated = q.act(from)
        #expect(distance(rotated, to) < 1e-4)
    }

    @MainActor @Test func lookOrientationFacesForward() {
        let forward = normalize(SIMD3<Float>(0.1, 0.6, 0.8))
        let q = CardInteractionController.lookOrientation(forward: forward, up: SIMD3<Float>(0, 1, 0))
        // The card front (+z) ends up along `forward`.
        let facing = q.act(SIMD3<Float>(0, 0, 1))
        #expect(distance(facing, forward) < 1e-4)
        // Unit quaternion.
        #expect(abs(simd_length(q.vector) - 1) < 1e-4)
    }
}
