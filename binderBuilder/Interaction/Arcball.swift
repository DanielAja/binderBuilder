//
//  Arcball.swift
//  binderBuilder
//
//  Shoemake arcball: maps two viewport points onto a virtual unit sphere and
//  returns the rotation between them. Used to spin a floating card with a
//  one-finger drag. Pure + nonisolated so it is unit-testable; the caller
//  composes the result into the camera frame so the card rotates the way the
//  finger moves on screen.
//

import CoreGraphics
import simd

nonisolated enum Arcball {
    /// Projects a viewport point to a point on the unit sphere (camera-local:
    /// +x right, +y up, +z toward the viewer). Points beyond the sphere edge
    /// fall onto the surrounding hyperbola so far drags still rotate smoothly.
    static func project(point: CGPoint, viewport: CGSize) -> SIMD3<Float> {
        guard viewport.width > 0, viewport.height > 0 else { return SIMD3<Float>(0, 0, 1) }
        let x = Float((point.x / viewport.width) * 2 - 1)
        let y = Float(1 - (point.y / viewport.height) * 2) // screen y is down
        let d2 = x * x + y * y
        if d2 <= 0.5 {
            return normalize(SIMD3<Float>(x, y, sqrt(1 - d2)))
        }
        // Hyperbolic sheet for points outside the sphere.
        return normalize(SIMD3<Float>(x, y, 0.5 / sqrt(d2)))
    }

    /// Camera-local rotation taking `from` to `to` on the sphere.
    static func rotation(from: SIMD3<Float>, to: SIMD3<Float>) -> simd_quatf {
        let axis = cross(from, to)
        let len = length(axis)
        if len < 1e-6 { return simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)) }
        let angle = acos(min(max(dot(from, to), -1), 1))
        return simd_quatf(angle: angle, axis: axis / len)
    }

    /// World-space rotation for a screen drag from `start` to `current`,
    /// expressed in the camera's frame so the card turns under the finger.
    static func worldRotation(
        start: CGPoint,
        current: CGPoint,
        viewport: CGSize,
        cameraOrientation: simd_quatf
    ) -> simd_quatf {
        let a = project(point: start, viewport: viewport)
        let b = project(point: current, viewport: viewport)
        let local = rotation(from: a, to: b)
        // Conjugate into world space: rotate in the camera's basis.
        return cameraOrientation * local * cameraOrientation.inverse
    }
}
