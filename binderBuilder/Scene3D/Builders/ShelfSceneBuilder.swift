//
//  ShelfSceneBuilder.swift
//  binderBuilder
//
//  The shelf "home" scene. Static furniture (room, shelf) is built once
//  here; the data-driven rows — one standing binder per stored Binder on the
//  low slab, the display cases with their cards on the high slab — are
//  (re)built by ShelfController through the makeBinderEntity/makeDisplaySlot
//  helpers below whenever the stores change.
//
//  Tapping a binder opens THAT binder; tapping a display case picks/edits
//  its card; tapping the ghost pedestal adds another case.
//
//  Asset facts (from tools/blender/gen_assets.py, meters, Y-up after export):
//   - Shelf: 1.2(x) x 0.26(depth +z) x 0.72(y) — origin back-bottom on y=0,
//     extends toward +z; slab tops at y≈0.028 (low) and y≈0.448 (high).
//   - Binder (closed): 0.26(x) x 0.32 x 0.05 lying flat (local: XY covers,
//     +Z front cover, spine on the -X edge); stood upright here.
//   - GlassCase: 0.09(x) x 0.03(depth) x 0.12(y), base on the slab.
//   - CardStand: easel, ~0.068 wide, legs tilted -16°, origin at its base.
//

import OSLog
import RealityKit
import UIKit
import simd

/// Marks a tappable shelf object for the mode controller's ray pick.
struct ShelfTargetComponent: Component {
    enum Kind: Equatable {
        case binder(id: String)
        case display(Int)
        case addDisplay
    }
    var kind: Kind
}

@MainActor
struct ShelfRig {
    let root: Entity
    /// Parent for the per-binder entities (ShelfController fills it).
    let binderRow: Entity
    /// Parent for the display cases + ghost pedestal (ShelfController fills it).
    let displayRow: Entity
}

@MainActor
enum ShelfSceneBuilder {
    private static let log = Logger(subsystem: "com.aja.binderBuilder", category: "ShelfScene")

    static let lowSlabTopY: Float = 0.028
    static let highSlabTopY: Float = 0.448
    /// Shelf usable depth midline (z toward viewer).
    static let slabCenterZ: Float = 0.12

    /// Display cases render enlarged so a near-full-size card + stand fit
    /// inside the glass.
    static let caseScale: Float = 1.3
    static let standScale: Float = 1.1
    static let cardScale: Float = 1.1

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

        let binderRow = Entity()
        binderRow.name = "BinderRow"
        root.addChild(binderRow)

        let displayRow = Entity()
        displayRow.name = "DisplayRow"
        root.addChild(displayRow)

        return ShelfRig(root: root, binderRow: binderRow, displayRow: displayRow)
    }

    // MARK: Templates (loaded once by ShelfController, cloned per item)

    static func loadBinderTemplate() -> Entity {
        (try? Entity.load(named: "Binder.usdz")) ?? proceduralBinder()
    }

    static func loadCaseTemplate() -> Entity {
        (try? Entity.load(named: "GlassCase.usdz")) ?? proceduralCase()
    }

    static func loadStandTemplate() -> Entity? {
        try? Entity.load(named: "CardStand.usdz")
    }

    // MARK: Binder row

    /// A standing shelf binder for one stored Binder: cover + spine tinted to
    /// its color, a name plaque (front plaque face-out, spine plaque for the
    /// book row), tap target, and collider.
    ///
    /// Returned as a CONTAINER entity (identity orientation, standing pose
    /// baked into the model child) so the plaques attach in upright viewer
    /// space — reasoning about text orientation inside the rotated USDZ
    /// local space is a trap.
    static func makeBinderEntity(
        _ binder: Binder,
        placement: ShelfLayout.BinderPlacement,
        template: Entity
    ) -> Entity {
        let container = Entity()
        container.name = "ShelfBinder-\(binder.id)"

        let model = template.clone(recursive: true)
        tintCovers(of: model, hex: binder.coverColor)

        // Imported lying flat (thickness up): stand it on its bottom edge with
        // the front cover facing the viewer. The 180° in-plane roll corrects
        // the upside-down result of the stand rotation alone.
        let standUp =
            simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 0, 1))
            * simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        if placement.faceOut {
            model.orientation = standUp
        } else {
            // Book row: quarter-turn so the spine faces the viewer.
            model.orientation =
                simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(0, 1, 0)) * standUp
        }
        container.addChild(model)
        attachPlaque(to: container, name: binder.name, spineSide: !placement.faceOut)

        // The relaxed lean for the last book, about the viewer axis, applied
        // to the container so the plaque leans with it.
        if placement.lean != 0 {
            container.orientation = simd_quatf(angle: placement.lean, axis: SIMD3<Float>(0, 0, 1))
        }
        container.position = SIMD3<Float>(
            placement.x + (placement.lean != 0 ? sinf(placement.lean) * 0.16 : 0),
            lowSlabTopY + 0.16,
            slabCenterZ)

        container.components.set(ShelfTargetComponent(kind: .binder(id: binder.id)))
        container.components.set(CollisionComponent(shapes: [
            .generateBox(width: placement.faceOut ? 0.26 : 0.07, height: 0.32, depth: placement.faceOut ? 0.06 : 0.26)
        ]))
        return container
    }

    /// Recolors the Blender binder's leather by entity name (FrontCover,
    /// BackCover, Spine — authored in gen_assets.py and stable through USDZ
    /// export). Falls back to a thin tinted cover skin if the names are gone.
    private static func tintCovers(of entity: Entity, hex: String) {
        let color = uiColor(hex: hex) ?? UIColor(red: 0.11, green: 0.42, blue: 0.66, alpha: 1)
        var tinted = false
        for name in ["FrontCover", "BackCover"] {
            if let cover = entity.findEntity(named: name) {
                applyTint(color, to: cover)
                tinted = true
            }
        }
        if let spine = entity.findEntity(named: "Spine") {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            applyTint(UIColor(hue: h, saturation: s, brightness: b * 0.72, alpha: 1), to: spine)
        }
        if !tinted {
            log.error("Binder cover entities not found; overlaying cover skin")
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(tint: color)
            material.roughness = 0.55
            let skin = ModelEntity(
                mesh: .generateBox(width: 0.252, height: 0.312, depth: 0.0008),
                materials: [material])
            skin.position = SIMD3<Float>(0, 0, 0.0256)
            entity.addChild(skin)
        }
    }

    private static func applyTint(_ color: UIColor, to entity: Entity) {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.roughness = 0.55
        material.metallic = 0.0
        func visit(_ current: Entity) {
            if var model = current.components[ModelComponent.self] {
                model.materials = model.materials.map { _ in material }
                current.components.set(model)
            }
            for child in current.children { visit(child) }
        }
        visit(entity)
    }

    /// Name plaque, in the container's upright space (plane faces the viewer,
    /// +Z): low on the front cover for face-out binders, running up the spine
    /// for the book row. The binder stands centered on the container origin:
    /// 0.32 tall (y ±0.16), 0.05 thick (z ±0.025 face-out, x ±0.025 books).
    private static func attachPlaque(to container: Entity, name: String, spineSide: Bool) {
        guard let texture = BinderLabelTexture.make(name: name, vertical: spineSide) else { return }
        var material = UnlitMaterial()
        material.color = .init(texture: .init(texture))

        if spineSide {
            // Vertical text texture on a tall thin plane, proud of the spine
            // (the book's covers run backward from it, z +0.13 ... -0.13).
            let plaque = ModelEntity(mesh: .generatePlane(width: 0.034, height: 0.26), materials: [material])
            plaque.position = SIMD3<Float>(0, 0, 0.1312)
            container.addChild(plaque)
        } else {
            let plaque = ModelEntity(mesh: .generatePlane(width: 0.11, height: 0.0275), materials: [material])
            plaque.position = SIMD3<Float>(0, -0.106, 0.0262)
            container.addChild(plaque)
        }
    }

    // MARK: Display row

    /// One display-case slot: the glass case (scaled up), the card stand
    /// inside it, tap target + collider. The card itself is spawned by
    /// ShelfController so it can diff/re-texture without rebuilding the case.
    static func makeDisplaySlot(
        index: Int,
        x: Float,
        caseTemplate: Entity,
        standTemplate: Entity?
    ) -> Entity {
        let slot = Entity()
        slot.name = "DisplaySlot\(index)"
        slot.position = SIMD3<Float>(x, highSlabTopY, slabCenterZ)

        let caseEntity = caseTemplate.clone(recursive: true)
        caseEntity.name = "Case\(index)"
        caseEntity.scale = SIMD3<Float>(repeating: caseScale)
        slot.addChild(caseEntity)

        if let standTemplate {
            let stand = standTemplate.clone(recursive: true)
            stand.name = "Stand\(index)"
            stand.scale = SIMD3<Float>(repeating: standScale)
            // Atop the case's wooden base (which scales with the case).
            stand.position = SIMD3<Float>(0, 0.016 * caseScale, -0.002)
            slot.addChild(stand)
        }

        slot.components.set(ShelfTargetComponent(kind: .display(index)))
        slot.components.set(CollisionComponent(shapes: [
            .generateBox(width: 0.09 * caseScale, height: 0.12 * caseScale, depth: 0.035 * caseScale)
                .offsetBy(translation: SIMD3<Float>(0, 0.06 * caseScale, 0))
        ]))
        return slot
    }

    /// The ghost "add another display" pedestal at the end of the case row.
    static func makeAddPedestal(x: Float) -> Entity {
        let slot = Entity()
        slot.name = "AddDisplay"
        slot.position = SIMD3<Float>(x, highSlabTopY, slabCenterZ)

        var base = PhysicallyBasedMaterial()
        base.baseColor = .init(tint: UIColor(white: 0.85, alpha: 0.35))
        base.roughness = 0.4
        base.blending = .transparent(opacity: .init(floatLiteral: 0.35))
        let pedestal = ModelEntity(
            mesh: .generateBox(width: 0.075, height: 0.012, depth: 0.05, cornerRadius: 0.004),
            materials: [base])
        pedestal.position = SIMD3<Float>(0, 0.006, 0)
        slot.addChild(pedestal)

        // A soft white "+" floating where a case's card would stand.
        var plusMaterial = UnlitMaterial(color: UIColor(white: 0.95, alpha: 0.8))
        plusMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.8))
        let horizontal = ModelEntity(
            mesh: .generateBox(width: 0.032, height: 0.006, depth: 0.004, cornerRadius: 0.002),
            materials: [plusMaterial])
        let vertical = ModelEntity(
            mesh: .generateBox(width: 0.006, height: 0.032, depth: 0.004, cornerRadius: 0.002),
            materials: [plusMaterial])
        horizontal.position = SIMD3<Float>(0, 0.055, 0)
        vertical.position = SIMD3<Float>(0, 0.055, 0)
        slot.addChild(horizontal)
        slot.addChild(vertical)

        slot.components.set(ShelfTargetComponent(kind: .addDisplay))
        slot.components.set(CollisionComponent(shapes: [
            .generateBox(width: 0.09, height: 0.12, depth: 0.05)
                .offsetBy(translation: SIMD3<Float>(0, 0.05, 0))
        ]))
        return slot
    }

    // MARK: Colors

    /// "#RRGGBB" -> UIColor (nil for anything else).
    static func uiColor(hex: String) -> UIColor? {
        var value = hex.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("#") else { return nil }
        value.removeFirst()
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1)
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
