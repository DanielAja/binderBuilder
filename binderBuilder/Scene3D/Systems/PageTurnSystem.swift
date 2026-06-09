//
//  PageTurnSystem.swift
//  binderBuilder
//
//  RealityKit System that advances every pooled page's curl state machine
//  each frame:
//  - springs step with the analytic critically-damped solution (occupancy-
//    adjusted omega lives inside FlipSpring; see PageDynamics),
//  - gesture psi decays exponentially while springing so released corners
//    settle flat,
//  - sag is recomputed from occupancy and t, packed into the shader uniform,
//  - entity height lerps (smoothstep in t) between the right and left stack
//    tops so pages land exactly on their destination stack,
//  - settled springs snap to their target and are reported AFTER the query
//    iteration through `onFlipSettled` (the handler rebinds the pool, which
//    mutates components — unsafe to do mid-iteration).
//
//  Deformers are class instances owned by the pool; entities can't carry
//  them as Codable component state, so the system looks them up in a
//  MainActor registry keyed by entity ID (registered by BinderFlipController).
//

import RealityKit
import simd

@MainActor
final class PageTurnSystem: System {
    private static let query = EntityQuery(where: .has(PageComponent.self))

    /// Deformer registry: entity ID -> the deformer driving that page.
    static var deformers: [Entity.ID: any PageDeformer] = [:]
    /// Called once per completed flip, after the frame's query iteration.
    static var onFlipSettled: ((Entity, PageComponent) -> Void)?

    /// Exponential decay rate for gesture psi while springing (1/s).
    static let psiDecayRate: Float = 6
    /// Cap on total curl-axis tilt (radians).
    static let maxTotalPsi: Float = 0.6

    private static var didRegister = false

    /// Registers the component + system exactly once. Call before assembling
    /// the scene.
    static func ensureRegistered() {
        guard !didRegister else { return }
        didRegister = true
        PageComponent.registerComponent()
        registerSystem()
    }

    init(scene: Scene) {}

    func update(context: SceneUpdateContext) {
        let dt = Float(context.deltaTime)
        var settled: [(Entity, PageComponent)] = []

        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard var page = entity.components[PageComponent.self] else { continue }

            switch page.phase {
            case .rest, .dragging:
                break
            case .springing(var spring):
                spring.step(dt: dt)
                page.gesturePsi *= exp(-Self.psiDecayRate * dt)
                if spring.isSettled {
                    page.phase = .rest(t: spring.target)
                    page.gesturePsi = 0
                    settled.append((entity, page))
                } else {
                    page.phase = .springing(spring)
                }
            }

            let t = page.currentT
            var params = CurlParams.progress(t)
            params.psi = min(max(params.psi + page.gesturePsi, -Self.maxTotalPsi), Self.maxTotalPsi)
            params.sag = PageDynamics.sag(occupiedSlots: page.occupiedBothSides, t: t)

            // Height: smoothstep lerp between the two stack tops.
            let s = t * t * (3 - 2 * t)
            let y = page.restYRight + (page.restYLeft - page.restYRight) * s

            if page.appliedParams != params {
                Self.deformers[entity.id]?.update(curl: params, on: entity)
                page.appliedParams = params
            }
            if abs(entity.position.y - y) > 1e-6 {
                entity.position.y = y
            }
            entity.components.set(page)
        }

        for (entity, page) in settled {
            Self.onFlipSettled?(entity, page)
        }
    }
}
