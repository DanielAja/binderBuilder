//
//  CardFloatSystem.swift
//  binderBuilder
//
//  Drives a card that has been pulled out of its sleeve and floats in front of
//  the camera. Per frame:
//   - a critically-damped spring eases its position toward the float target
//     (the pull-out animation) or back to its home pocket (the return),
//   - until the user grabs it, its orientation slerps to face the camera,
//   - after a flick, angular-velocity inertia spins it down (omega *= e^-3.5dt),
//   - on a settled return it reparents back under its page and hands control
//     back to CardPlacementSystem.
//

import RealityKit
import simd

/// State for a floating (pulled-out) card. Reparented to the scene root so the
/// page systems leave it alone; CardSlotComponent stays attached so the holo
/// sweep still applies.
struct CardFloatComponent: Component {
    enum Mode: Equatable { case active, returning }
    var mode: Mode
    /// Page entity to reparent under on return, and the local transform to
    /// restore there.
    var homeParent: Entity?
    var homeLocal: Transform
    /// World-space spring targets.
    var targetPosition: SIMD3<Float>
    var targetOrientation: simd_quatf
    var velocity: SIMD3<Float> = .zero
    /// World angular velocity (axis * rad/s) for flick inertia.
    var spin: SIMD3<Float> = .zero
    /// True while the finger is rotating the card (suppresses auto-orient/spin).
    var userControlled: Bool = false
}

@MainActor
final class CardFloatSystem: System {
    private static let query = EntityQuery(where: .has(CardFloatComponent.self))
    private static var didRegister = false

    /// Position spring stiffness (rad/s) and orientation slerp rate (1/s).
    static let positionOmega: Float = 13
    static let orientRate: Float = 12
    static let spinDecay: Float = 3.5
    static let returnDistance: Float = 0.004

    static func ensureRegistered() {
        guard !didRegister else { return }
        didRegister = true
        CardFloatComponent.registerComponent()
        registerSystem()
    }

    init(scene: Scene) {}

    func update(context: SceneUpdateContext) {
        let dt = Float(context.deltaTime)
        guard dt > 0 else { return }
        var finished: [(Entity, CardFloatComponent)] = []

        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard var f = entity.components[CardFloatComponent.self] else { continue }

            // Position: critically-damped spring (root-local == world).
            var pos = entity.position
            let omega = Self.positionOmega
            let accel = omega * omega * (f.targetPosition - pos) - 2 * omega * f.velocity
            f.velocity += accel * dt
            pos += f.velocity * dt
            entity.position = pos

            if f.userControlled {
                // Orientation is driven directly by the drag; nothing to do.
            } else if length(f.spin) > 0.01 {
                // Flick inertia.
                let angle = length(f.spin) * dt
                let axis = normalize(f.spin)
                entity.orientation = simd_quatf(angle: angle, axis: axis) * entity.orientation
                f.spin *= exp(-Self.spinDecay * dt)
            } else {
                // Ease toward the target orientation (face camera / home).
                let s = min(1, Self.orientRate * dt)
                entity.orientation = simd_slerp(entity.orientation, f.targetOrientation, s)
            }

            if f.mode == .returning,
               distance(pos, f.targetPosition) < Self.returnDistance,
               length(f.velocity) < 0.03 {
                finished.append((entity, f))
            } else {
                entity.components.set(f)
            }
        }

        for (entity, f) in finished { Self.finalizeReturn(entity, f) }
    }

    /// Reparents a returned card under its page and restores pocket control.
    private static func finalizeReturn(_ entity: Entity, _ f: CardFloatComponent) {
        entity.components.remove(CardFloatComponent.self)
        if let parent = f.homeParent {
            parent.addChild(entity) // keep current world transform irrelevant; reset below
            entity.transform = f.homeLocal
        }
        // Force CardPlacementSystem to re-pose it at the pocket curl frame.
        if var slot = entity.components[CardSlotComponent.self] {
            slot.lastParams = nil
            entity.components.set(slot)
        }
    }
}
