//
//  HitTarget.swift
//  binderBuilder
//
//  Touch-down picking for the binder scene. Two interchangeable testers
//  behind the HitTesting seam:
//  - SceneRaycastHitTester: scene.raycast against static box
//    CollisionComponents on the page pick zones and covers.
//  - AnalyticHitTester: ray vs oriented-bounding-box intersection over the
//    same zones, computed without RealityKit physics (fallback in case
//    scene.raycast misbehaves under the virtual camera).
//  CompositeHitTester runs raycast first, falls back to analytic, and
//  remembers which one answered (logged + used by the startup self-probe).
//

import OSLog
import RealityKit
import simd

/// What a ray can land on in the binder scene.
nonisolated enum HitZoneKind: String, Sendable {
    case leftPage
    case rightPage
    case leftCover
    case rightCover
}

/// Marks an entity as a pick target for SceneRaycastHitTester.
struct HitZoneComponent: Component {
    var kind: HitZoneKind
}

nonisolated struct HitResult: Equatable, Sendable {
    var kind: HitZoneKind
    var worldPoint: SIMD3<Float>
}

/// Oriented bounding box for the analytic tester.
nonisolated struct OBB: Sendable {
    var center: SIMD3<Float>
    var halfExtents: SIMD3<Float>
    var orientation: simd_quatf

    init(center: SIMD3<Float>, halfExtents: SIMD3<Float>, orientation: simd_quatf = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))) {
        self.center = center
        self.halfExtents = halfExtents
        self.orientation = orientation
    }
}

@MainActor
protocol HitTesting: AnyObject {
    var debugLabel: String { get }
    func hitTest(origin: SIMD3<Float>, direction: SIMD3<Float>) -> HitResult?
}

// MARK: - scene.raycast path

@MainActor
final class SceneRaycastHitTester: HitTesting {
    let debugLabel = "raycast"
    /// Any entity attached to the scene (used to reach `scene`).
    private weak var sceneAnchor: Entity?

    init(sceneAnchor: Entity) {
        self.sceneAnchor = sceneAnchor
    }

    func hitTest(origin: SIMD3<Float>, direction: SIMD3<Float>) -> HitResult? {
        guard let scene = sceneAnchor?.scene else { return nil }
        let hits = scene.raycast(
            origin: origin,
            direction: direction,
            length: 10,
            query: .all,
            mask: .all,
            relativeTo: nil
        )
        // Nearest hit that resolves to a tagged zone (walk up the ancestors
        // in case collision lands on a child).
        for hit in hits.sorted(by: { $0.distance < $1.distance }) {
            var entity: Entity? = hit.entity
            while let current = entity {
                if let zone = current.components[HitZoneComponent.self] {
                    return HitResult(kind: zone.kind, worldPoint: hit.position)
                }
                entity = current.parent
            }
        }
        return nil
    }
}

// MARK: - Analytic OBB path

@MainActor
final class AnalyticHitTester: HitTesting {
    let debugLabel = "analytic"
    /// Pulls fresh zones on every test so stack-height changes never go stale.
    private let zoneProvider: () -> [(kind: HitZoneKind, obb: OBB)]

    init(zoneProvider: @escaping () -> [(kind: HitZoneKind, obb: OBB)]) {
        self.zoneProvider = zoneProvider
    }

    func hitTest(origin: SIMD3<Float>, direction: SIMD3<Float>) -> HitResult? {
        var best: (kind: HitZoneKind, distance: Float)?
        for zone in zoneProvider() {
            if let distance = GestureMath.rayOBBIntersection(
                origin: origin, direction: direction, obb: zone.obb
            ), distance >= 0, distance < (best?.distance ?? .greatestFiniteMagnitude) {
                best = (zone.kind, distance)
            }
        }
        guard let best else { return nil }
        return HitResult(kind: best.kind, worldPoint: origin + direction * best.distance)
    }
}

// MARK: - Composite

@MainActor
final class CompositeHitTester: HitTesting {
    var debugLabel: String { "composite(\(lastUsed ?? "unused"))" }
    private let primary: any HitTesting
    private let fallback: any HitTesting
    private(set) var lastUsed: String?
    private let log = Logger(subsystem: "com.aja.binderBuilder", category: "HitTesting")

    init(primary: any HitTesting, fallback: any HitTesting) {
        self.primary = primary
        self.fallback = fallback
    }

    func hitTest(origin: SIMD3<Float>, direction: SIMD3<Float>) -> HitResult? {
        if let hit = primary.hitTest(origin: origin, direction: direction) {
            lastUsed = primary.debugLabel
            return hit
        }
        if let hit = fallback.hitTest(origin: origin, direction: direction) {
            lastUsed = fallback.debugLabel
            log.info("Primary tester missed; analytic fallback hit \(hit.kind.rawValue, privacy: .public)")
            return hit
        }
        return nil
    }

    /// Startup self-check: casts a known ray at each side and logs which
    /// implementation answers, so simulator runs can verify the raycast path
    /// actually works under the virtual camera.
    func probe(origin: SIMD3<Float>, direction: SIMD3<Float>) -> String {
        let p = primary.hitTest(origin: origin, direction: direction)
        let f = fallback.hitTest(origin: origin, direction: direction)
        let summary = "hitProbe primary(\(primary.debugLabel))="
            + (p.map { $0.kind.rawValue } ?? "miss")
            + " fallback(\(fallback.debugLabel))="
            + (f.map { $0.kind.rawValue } ?? "miss")
        log.info("\(summary, privacy: .public)")
        return summary
    }
}
