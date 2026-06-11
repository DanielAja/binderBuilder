//
//  CardInteractionController.swift
//  binderBuilder
//
//  The card pull-out / inspect / return interaction, fed by BinderSceneView's
//  tap and drag gestures:
//   - tap a seated card  -> ray-pick it, reparent to the scene root, and spring
//     it out of the sleeve to a pose floating in front of the camera,
//   - drag while a card floats -> Shoemake arcball spins it under the finger,
//   - release a spin       -> flick inertia (handled by CardFloatSystem),
//   - tap while a card floats -> spring it back into its pocket.
//  CardFloatSystem owns the per-frame springs/inertia; this controller owns
//  picking, the state transitions, and feeding the arcball.
//

import CoreGraphics
import RealityKit
import UIKit
import simd

@MainActor
final class CardInteractionController {
    private let root: Entity
    private let cameraRig: CameraRig

    // Touch haptics for handling the floating card.
    private let softHaptic = UIImpactFeedbackGenerator(style: .soft)
    private let rigidHaptic = UIImpactFeedbackGenerator(style: .rigid)
    /// Accumulated rotation (radians) since the last haptic "tick".
    private var rotationSinceTick: Float = 0

    private(set) weak var floatingCard: ModelEntity?
    var isFloating: Bool { floatingCard != nil }

    /// CardRef of the floating card, if any (drives the owned-toggle control).
    var floatingRef: CardRef? { floatingCard?.components[CardSlotComponent.self]?.ref }

    /// Updates the floating card's grayscale/foil to reflect a new owned state.
    func setFloatingOwned(_ owned: Bool) {
        guard let card = floatingCard, let slot = card.components[CardSlotComponent.self] else { return }
        CardFactory.setOwnership(card, owned: owned, variant: slot.ref.variant)
    }

    /// Distance in front of the camera the inspected card floats to (m).
    private let floatDistance: Float = 0.26

    // Active-drag arcball state.
    private var dragStart: CGPoint?
    private var dragStartOrientation: simd_quatf?
    private var lastDragPoint: CGPoint?

    init(root: Entity, cameraRig: CameraRig) {
        self.root = root
        self.cameraRig = cameraRig
    }

    // MARK: Tap

    /// A tap: pull the nearest card out, or return the floating one.
    func handleTap(at point: CGPoint, viewport: CGSize) {
        if isFloating {
            returnCard()
        } else if let card = pick(at: point, viewport: viewport) {
            pullOut(card)
        }
    }

    /// Auto-pull a specific card (debug / -uiState cardFloating), optionally
    /// settling it at a yaw so the foil shows at an angle in screenshots.
    func pullOutFirstAvailable(yawDegrees: Float? = nil) {
        guard let card = collectCards().first else { return }
        pullOut(card)
        // Debug only: zero the foil so text is legible in verification shots.
        if ProcessInfo.processInfo.arguments.contains("-noHolo"),
           var model = card.components[ModelComponent.self],
           var mat = model.materials.first as? CustomMaterial {
            var v = mat.custom.value; v.x = 0; mat.custom.value = v
            model.materials[0] = mat; card.components.set(model)
        }
        if let yawDegrees, var f = card.components[CardFloatComponent.self] {
            let yaw = simd_quatf(angle: yawDegrees * .pi / 180, axis: SIMD3<Float>(0, 1, 0))
            f.targetOrientation = f.targetOrientation * yaw
            card.components.set(f)
        }
    }

    // MARK: Drag (arcball while floating)

    func dragChanged(location: CGPoint, viewport: CGSize) {
        guard let card = floatingCard else { return }
        let camOrientation = cameraRig.camera.orientation(relativeTo: nil)
        if dragStart == nil {
            dragStart = location
            lastDragPoint = location
            dragStartOrientation = card.orientation
            rotationSinceTick = 0
            softHaptic.prepare()
            rigidHaptic.prepare()
            softHaptic.impactOccurred(intensity: 0.6)   // "picked it up"
            if var f = card.components[CardFloatComponent.self] {
                f.userControlled = true
                f.spin = .zero
                card.components.set(f)
            }
        }
        guard let start = dragStart, let base = dragStartOrientation, let last = lastDragPoint else { return }

        // Soft tick every ~18° of rotation, so spinning the card feels textured.
        let step = Arcball.worldRotation(start: last, current: location, viewport: viewport,
                                         cameraOrientation: camOrientation)
        rotationSinceTick += axisAngle(step).angle
        if rotationSinceTick >= 0.32 {
            softHaptic.impactOccurred(intensity: 0.4)
            softHaptic.prepare()
            rotationSinceTick = 0
        }

        let q = Arcball.worldRotation(
            start: start, current: location, viewport: viewport, cameraOrientation: camOrientation
        )
        card.orientation = q * base
        lastDragPoint = location
    }

    func dragEnded(velocity: CGSize, viewport: CGSize) {
        guard let card = floatingCard, let last = lastDragPoint,
              var f = card.components[CardFloatComponent.self] else {
            resetDrag()
            return
        }
        // Convert the release screen velocity into a world angular velocity by
        // projecting a short look-ahead through the arcball.
        let dt0: CGFloat = 1.0 / 60.0
        let ahead = CGPoint(x: last.x + velocity.width * dt0, y: last.y + velocity.height * dt0)
        let camOrientation = cameraRig.camera.orientation(relativeTo: nil)
        let step = Arcball.worldRotation(
            start: last, current: ahead, viewport: viewport, cameraOrientation: camOrientation
        )
        let (axis, angle) = axisAngle(step)
        f.userControlled = false
        f.spin = angle > 1e-4 ? axis * (angle / Float(dt0)) : .zero
        card.components.set(f)
        // A release "flick" thump scaled to how hard it was spun.
        let spinMag = length(f.spin)
        if spinMag > 0.4 {
            rigidHaptic.impactOccurred(intensity: CGFloat(min(1, spinMag / 12)))
        }
        resetDrag()
    }

    private func resetDrag() {
        dragStart = nil
        dragStartOrientation = nil
        lastDragPoint = nil
    }

    // MARK: Pull-out / return

    private func pullOut(_ card: ModelEntity) {
        let homeParent = card.parent
        let homeLocal = card.transform
        // Reparent to the scene root, keeping its current on-page world pose so
        // it springs smoothly from the sleeve rather than jumping.
        root.addChild(card, preservingWorldTransform: true)

        let camPos = cameraRig.camera.position(relativeTo: nil)
        let camOrientation = cameraRig.camera.orientation(relativeTo: nil)
        let forward = camOrientation.act(SIMD3<Float>(0, 0, -1))
        let target = camPos + forward * floatDistance

        // The seated card already renders correctly (upright, un-mirrored), so
        // rotate that exact world orientation by the MINIMAL rotation that turns
        // its front (+z) to face the camera. A pure rotation can't mirror or
        // flip it — it just stands the card up toward the viewer.
        let seated = card.orientation(relativeTo: nil)
        let cardFront = seated.act(SIMD3<Float>(0, 0, 1))
        let toCamera = normalize(camPos - target)
        let faceCamera: simd_quatf
        let axis = cross(cardFront, toCamera)
        let axisLen = length(axis)
        if axisLen > 1e-5 {
            let angle = acos(max(-1, min(1, dot(cardFront, toCamera))))
            faceCamera = simd_quatf(angle: angle, axis: axis / axisLen) * seated
        } else {
            faceCamera = seated
        }

        card.components.set(CardFloatComponent(
            mode: .active,
            homeParent: homeParent,
            homeLocal: homeLocal,
            targetPosition: target,
            targetOrientation: faceCamera
        ))
        floatingCard = card
        softHaptic.impactOccurred(intensity: 0.7)   // pops out of the sleeve
    }

    private func returnCard() {
        guard let card = floatingCard, var f = card.components[CardFloatComponent.self],
              let parent = f.homeParent else {
            floatingCard = nil
            return
        }
        // Recompute the home pose in world space (the page may have moved).
        let homeWorld = parent.transformMatrix(relativeTo: nil) * f.homeLocal.matrix
        f.mode = .returning
        f.targetPosition = SIMD3<Float>(homeWorld.columns.3.x, homeWorld.columns.3.y, homeWorld.columns.3.z)
        f.targetOrientation = parent.orientation(relativeTo: nil) * f.homeLocal.rotation
        f.userControlled = false
        f.spin = .zero
        card.components.set(f)
        floatingCard = nil
        resetDrag()
        softHaptic.impactOccurred(intensity: 0.45)   // slides back into the sleeve
    }

    // MARK: Picking

    private func pick(at point: CGPoint, viewport: CGSize) -> ModelEntity? {
        let ray = cameraRig.ray(through: point, viewport: viewport)
        let half = SIMD3<Float>(CardMesh.width / 2, CardMesh.height / 2, CardMesh.thickness / 2)
        var best: (card: ModelEntity, distance: Float)?
        for card in collectCards() {
            let obb = OBB(
                center: card.position(relativeTo: nil),
                halfExtents: half,
                orientation: card.orientation(relativeTo: nil)
            )
            if let d = GestureMath.rayOBBIntersection(origin: ray.origin, direction: ray.direction, obb: obb),
               d >= 0, d < (best?.distance ?? .greatestFiniteMagnitude) {
                best = (card, d)
            }
        }
        return best?.card
    }

    private func collectCards() -> [ModelEntity] {
        var out: [ModelEntity] = []
        func walk(_ entity: Entity) {
            if entity.components.has(CardSlotComponent.self), let model = entity as? ModelEntity {
                out.append(model)
            }
            for child in entity.children { walk(child) }
        }
        walk(root)
        return out
    }

    private func axisAngle(_ q: simd_quatf) -> (axis: SIMD3<Float>, angle: Float) {
        let n = q.normalized
        let angle = 2 * acos(min(max(n.real, -1), 1))
        let s = sqrt(max(0, 1 - n.real * n.real))
        let axis = s < 1e-5 ? SIMD3<Float>(0, 1, 0) : n.imag / s
        return (axis, angle)
    }
}
