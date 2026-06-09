//
//  PageComponents.swift
//  binderBuilder
//
//  ECS state for the interactive page flip:
//  - FlipSpring: analytic critically-damped spring on the curl progress t.
//  - PageComponent: per-pooled-page curl state machine (rest / dragging /
//    springing) advanced every frame by PageTurnSystem.
//  - PageDynamics: occupancy-aware feel — massFactor stiffens/slows the
//    spring (omega = omega0 / sqrt(massFactor)) and scales the sag droop.
//

import RealityKit
import simd

/// Critically-damped spring on the flip progress t, stepped with the exact
/// analytic solution x(s) = target + (x0 + (v0 + w*x0) * s) * e^(-w*s) so it
/// is unconditionally stable for any frame dt.
nonisolated struct FlipSpring: Equatable, Sendable {
    var t: Float
    var velocity: Float
    /// Where the page is heading: 0 (flat on right) or 1 (flat on left).
    var target: Float
    /// Natural frequency (rad/s), already mass-adjusted.
    var omega: Float

    /// Settle thresholds: loose enough that a ~2 s scripted flip visibly
    /// completes (stack rebind) right after it looks settled on screen.
    static let settleDistance: Float = 0.005
    static let settleVelocity: Float = 0.05

    mutating func step(dt: Float) {
        guard dt > 0 else { return }
        let x0 = t - target
        let b = velocity + omega * x0
        let e = exp(-omega * dt)
        t = target + (x0 + b * dt) * e
        velocity = (b - omega * (x0 + b * dt)) * e
    }

    var isSettled: Bool {
        abs(t - target) < Self.settleDistance && abs(velocity) < Self.settleVelocity
    }
}

/// Occupancy-aware flip dynamics. A pocketful of cards makes a page heavier:
/// its release spring slows by 1/sqrt(massFactor) and it sags more mid-flip.
nonisolated enum PageDynamics {
    /// Natural frequency of an EMPTY page's release spring (rad/s).
    static let omega0: Float = 10
    /// Sag droop per occupied pocket (m); 18 pockets ~ 1.26 cm mid-flip.
    static let sagPerSlot: Float = 0.0007

    /// massFactor = 1 + 0.08 * occupied pockets on BOTH sides of the sheet.
    static func massFactor(occupiedSlots: Int) -> Float {
        1 + 0.08 * Float(max(0, occupiedSlots))
    }

    static func omega(omega0: Float = PageDynamics.omega0, occupiedSlots: Int) -> Float {
        omega0 / sqrt(massFactor(occupiedSlots: occupiedSlots))
    }

    /// Sag amplitude for a sheet at flip progress t: a sin(pi*t) bell so the
    /// page is rigid at both rest poses and droops most mid-flip, scaled by
    /// how many pockets it carries. Clamped to the packable maximum.
    static func sag(occupiedSlots: Int, t: Float) -> Float {
        let amplitude = min(CurlParams.maxSag, sagPerSlot * Float(max(0, occupiedSlots)))
        return amplitude * max(0, sin(.pi * min(max(t, 0), 1)))
    }
}

/// Curl state machine for one pooled page entity. PageTurnSystem advances
/// springs, decays gesture psi, computes sag, and applies the resulting
/// CurlParams through the page's deformer every frame.
struct PageComponent: Component {
    nonisolated enum Phase: Equatable, Sendable {
        /// Lying flat (t == 0 right / t == 1 left), or frozen via -curl.
        case rest(t: Float)
        /// Finger-driven: t and psi come straight from GestureRouter.
        case dragging(t: Float)
        /// Released or scripted: spring carries t to its target.
        case springing(FlipSpring)
    }

    /// Physical sheet this pooled entity currently represents.
    var sheetIndex: Int
    /// Occupied pockets on both sides — drives mass and sag.
    var occupiedBothSides: Int
    var phase: Phase
    /// Extra curl-axis tilt from the gesture (corner drags); decays to 0
    /// while springing.
    var gesturePsi: Float = 0
    /// World-Y rest heights at both ends of the flip (top of the right/left
    /// stack respectively). The system lerps entity height with smoothstep(t)
    /// so a page lands exactly on the destination stack even when the two
    /// stacks differ in thickness.
    var restYRight: Float = 0
    var restYLeft: Float = 0
    /// Last params applied to the deformer — lets the system skip redundant
    /// updates (important for the CPU deformer: pages at rest cost nothing).
    var appliedParams: CurlParams?

    var currentT: Float {
        switch phase {
        case .rest(let t): return t
        case .dragging(let t): return t
        case .springing(let spring): return spring.t
        }
    }
}
