//
//  ShelfSceneBuilder.swift
//  binderBuilder
//
//  The shelf "home" scene: the Blender wooden shelf with the closed binder
//  standing on the lower slab and three card display cases on the upper slab.
//  Tapping the binder dollies into the open-binder view; tapping a display
//  case (later) opens a picker. Assets load from the bundled USDZ (exported
//  Y-up); a procedural fallback keeps the scene usable if a load fails.
//
//  Asset facts (from tools/blender/gen_assets.py, meters, Y-up after export):
//   - Shelf: 1.2(x) x 0.26(depth +z) x 0.72(y) — origin back-bottom on y=0,
//     extends toward +z; slab tops at y≈0.028 (low) and y≈0.448 (high).
//   - Binder (closed): 0.26(x) x 0.32 x 0.05 lying flat; stood upright here.
//   - GlassCase: 0.09(x) x 0.03(depth) x 0.12(y), base on the slab.
//

import OSLog
import RealityKit
import UIKit
import simd

/// Marks a tappable shelf object for the mode controller's ray pick.
struct ShelfTargetComponent: Component {
    enum Kind: Equatable { case binder, display(Int) }
    var kind: Kind
}

@MainActor
struct ShelfRig {
    let root: Entity
    /// Standing binder (tap to open).
    let binder: Entity
    /// The three display-case anchor entities, left to right.
    let displaySlots: [Entity]
}

@MainActor
enum ShelfSceneBuilder {
    private static let log = Logger(subsystem: "com.aja.binderBuilder", category: "ShelfScene")

    static let lowSlabTopY: Float = 0.028
    static let highSlabTopY: Float = 0.448
    /// Shelf usable depth midline (z toward viewer).
    static let slabCenterZ: Float = 0.12

    static func build() -> ShelfRig {
        let root = Entity()
        root.name = "ShelfRoot"

        // Room backdrop (the wall the shelf hangs on + a floor) so the shelf
        // sits in a setting rather than floating in a gradient.
        root.addChild(makeRoomBackdrop())

        // Shelf furniture.
        if let shelf = try? Entity.load(named: "Shelf.usdz") {
            shelf.name = "Shelf"
            root.addChild(shelf)
        } else {
            log.error("Shelf.usdz failed to load; using procedural slab")
            root.addChild(proceduralShelf())
        }

        // Closed binder, stood upright on the low slab, front cover to viewer.
        let binder = (try? Entity.load(named: "Binder.usdz")) ?? proceduralBinder()
        binder.name = "ShelfBinder"
        // Imported lying flat (thickness up): stand it on its bottom edge with
        // the front cover facing the viewer. The 180 in-plane roll corrects the
        // upside-down result of the stand rotation alone.
        binder.orientation =
            simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 0, 1))
            * simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        binder.position = SIMD3<Float>(0, lowSlabTopY + 0.16, slabCenterZ)
        binder.components.set(ShelfTargetComponent(kind: .binder))
        binder.components.set(CollisionComponent(shapes: [
            .generateBox(width: 0.26, height: 0.32, depth: 0.05)
        ]))
        root.addChild(binder)

        // Three display cases on the high slab.
        var slots: [Entity] = []
        let xs: [Float] = [-0.34, 0, 0.34]
        for (index, x) in xs.enumerated() {
            let slot = Entity()
            slot.name = "DisplaySlot\(index)"
            slot.position = SIMD3<Float>(x, highSlabTopY, slabCenterZ)
            let caseEntity = (try? Entity.load(named: "GlassCase.usdz")) ?? proceduralCase()
            caseEntity.name = "Case\(index)"
            slot.addChild(caseEntity)
            slot.components.set(ShelfTargetComponent(kind: .display(index)))
            slot.components.set(CollisionComponent(shapes: [
                .generateBox(width: 0.09, height: 0.12, depth: 0.03)
                    .offsetBy(translation: SIMD3<Float>(0, 0.06, 0))
            ]))
            root.addChild(slot)
            slots.append(slot)
        }

        return ShelfRig(root: root, binder: binder, displaySlots: slots)
    }

    // MARK: Room backdrop

    /// A back wall (with a soft top-down light gradient) the shelf hangs on,
    /// plus a wood floor — turns the shelf into a room scene.
    private static func makeRoomBackdrop() -> Entity {
        let room = Entity()
        room.name = "ShelfRoom"

        var wallMat = PhysicallyBasedMaterial()
        if let tex = wallTexture() {
            wallMat.baseColor = .init(tint: .white, texture: .init(tex))
        } else {
            wallMat.baseColor = .init(tint: UIColor(red: 0.52, green: 0.48, blue: 0.45, alpha: 1))
        }
        wallMat.roughness = 0.96
        let wall = ModelEntity(mesh: .generatePlane(width: 5.0, height: 3.6), materials: [wallMat])
        wall.name = "ShelfWall"
        wall.position = SIMD3<Float>(0, 1.3, -0.06)
        room.addChild(wall)

        var floorMat = PhysicallyBasedMaterial()
        floorMat.baseColor = .init(tint: UIColor(red: 0.33, green: 0.23, blue: 0.15, alpha: 1))
        floorMat.roughness = 0.7
        let floor = ModelEntity(mesh: .generatePlane(width: 5.0, depth: 4.0), materials: [floorMat])
        floor.name = "ShelfFloor"
        floor.position = SIMD3<Float>(0, -0.012, 0.9)
        room.addChild(floor)

        return room
    }

    /// Warm wall colour with a gentle vertical light falloff for depth.
    private static func wallTexture() -> TextureResource? {
        let w = 16, h = 256
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        for y in 0..<h {
            // Cool, soft wall with a gentle light falloff — contrasts the warm
            // wood shelf so it pops. (Cooler/lighter near the top.)
            let t = Double(y) / Double(h - 1)
            let shade = 0.46 + 0.20 * t
            ctx.setFillColor(UIColor(red: shade * 0.92, green: shade * 0.97, blue: shade * 1.08, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: y, width: w, height: 1))
        }
        guard let image = ctx.makeImage() else { return nil }
        return try? TextureResource(image: image, options: .init(semantic: .color))
    }

    // MARK: Procedural fallbacks

    private static func proceduralShelf() -> Entity {
        var wood = PhysicallyBasedMaterial()
        wood.baseColor = .init(tint: .init(red: 0.18, green: 0.09, blue: 0.04, alpha: 1))
        wood.roughness = 0.6
        let e = ModelEntity(mesh: .generateBox(width: 1.2, height: 0.028, depth: 0.26), materials: [wood])
        e.position = SIMD3<Float>(0, lowSlabTopY - 0.014, slabCenterZ)
        return e
    }

    private static func proceduralBinder() -> Entity {
        var leather = PhysicallyBasedMaterial()
        leather.baseColor = .init(tint: .init(red: 0.23, green: 0.10, blue: 0.06, alpha: 1))
        leather.roughness = 0.62
        return ModelEntity(
            mesh: .generateBox(width: 0.26, height: 0.32, depth: 0.05, cornerRadius: 0.004),
            materials: [leather]
        )
    }

    private static func proceduralCase() -> Entity {
        var glass = PhysicallyBasedMaterial()
        glass.baseColor = .init(tint: .init(red: 0.82, green: 0.9, blue: 0.94, alpha: 1))
        glass.blending = .transparent(opacity: .init(floatLiteral: 0.18))
        let e = ModelEntity(mesh: .generateBox(width: 0.09, height: 0.12, depth: 0.03), materials: [glass])
        e.position = SIMD3<Float>(0, 0.06, 0)
        return e
    }
}
