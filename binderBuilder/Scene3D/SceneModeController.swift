//
//  SceneModeController.swift
//  binderBuilder
//
//  Switches the top-level 3D scene between the shelf "home" and the open
//  binder, dollying the camera between framings and toggling which root is
//  live (they occupy the same space, so only one shows at a time). Owns the
//  shelf tap routing: tap the standing binder to open it; tap a display case
//  to (future) pick a card.
//

import OSLog
import RealityKit
import simd

@MainActor
final class SceneModeController {
    private static let log = Logger(subsystem: "com.aja.binderBuilder", category: "SceneMode")

    private(set) var mode: AppMode
    private let cameraRig: CameraRig
    private let shelfRoot: Entity
    private let binderRoot: Entity
    /// Called when the binder opens (so the flip controller can refresh).
    var onEnterBinder: (() -> Void)?
    /// Called when a display case is tapped (index 0...2).
    var onTapDisplayCase: ((Int) -> Void)?

    var isShelf: Bool { mode == .shelf }

    // Shelf orbit state (committed) + the values captured at pan-start.
    private var shelfYaw: Float = 0
    private var shelfPitch: Float = 0
    private var panStartYaw: Float = 0
    private var panStartPitch: Float = 0

    init(mode: AppMode, cameraRig: CameraRig, shelfRoot: Entity, binderRoot: Entity) {
        self.mode = mode
        self.cameraRig = cameraRig
        self.shelfRoot = shelfRoot
        self.binderRoot = binderRoot
        applyImmediate(mode)
    }

    /// Snaps roots + camera to a mode without animation (initial setup).
    private func applyImmediate(_ mode: AppMode) {
        self.mode = mode
        let shelf = mode == .shelf
        shelfRoot.isEnabled = shelf
        binderRoot.isEnabled = !shelf
        cameraRig.apply(shelf ? .shelf : .binderOpen)
    }

    func enterBinder() {
        guard mode == .shelf else { return }
        mode = .binderOpen
        shelfRoot.isEnabled = false
        binderRoot.isEnabled = true
        cameraRig.animate(to: .binderOpen)
        onEnterBinder?()
        Self.log.info("Entered binder")
    }

    func enterShelf() {
        guard mode != .shelf else { return }
        mode = .shelf
        shelfYaw = 0
        shelfPitch = 0
        binderRoot.isEnabled = false
        shelfRoot.isEnabled = true
        cameraRig.animate(to: .shelf)
        Self.log.info("Returned to shelf")
    }

    // MARK: Shelf pan (orbit) — touch-drag to look around the shelf.

    /// Captures the orbit baseline at the start of a drag.
    func beginShelfPan() {
        panStartYaw = shelfYaw
        panStartPitch = shelfPitch
    }

    /// Orbits the camera from the drag translation (absolute, from pan-start).
    func updateShelfPan(translation: CGSize, viewport: CGSize) {
        guard mode == .shelf else { return }
        let w = max(Float(viewport.width), 1), h = max(Float(viewport.height), 1)
        // Drag spans ~full screen -> comfortable look-around range.
        shelfYaw = clamp(panStartYaw + Float(translation.width) / w * 1.8, -0.85, 0.85)
        shelfPitch = clamp(panStartPitch - Float(translation.height) / h * 1.2, -0.30, 0.55)
        cameraRig.setShelfOrbit(yaw: shelfYaw, pitch: shelfPitch)
    }

    private func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { min(max(v, lo), hi) }

    /// Handles a tap while on the shelf. Returns true if it hit something.
    @discardableResult
    func handleShelfTap(origin: SIMD3<Float>, direction: SIMD3<Float>) -> Bool {
        guard mode == .shelf, let scene = shelfRoot.scene else { return false }
        let hits = scene.raycast(origin: origin, direction: direction, length: 12, query: .nearest)
        for hit in hits.sorted(by: { $0.distance < $1.distance }) {
            var entity: Entity? = hit.entity
            while let current = entity {
                if let target = current.components[ShelfTargetComponent.self] {
                    switch target.kind {
                    case .binder: enterBinder()
                    case .display(let index): onTapDisplayCase?(index)
                    }
                    return true
                }
                entity = current.parent
            }
        }
        return false
    }
}
