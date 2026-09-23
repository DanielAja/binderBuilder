//
//  BinderBuilder3D.swift
//  binderBuilder
//
//  The open binder: two leather cover halves with a stitched border, the
//  spine strip bridging them, a three-ring mechanism on a metal plate down
//  the middle, the shadowed gutter either side of it, and two page-stack
//  slabs whose thicknesses track how many sheets rest on each side of the
//  open spread. Dimensions match the plan (binder ~0.32 x 0.26 x 0.05 m
//  closed, so each cover half is ~0.26 wide x 0.32 deep when open).
//
//  The rings are what make it read as a *binder* rather than a book, so they
//  are sized from the page stacks the way real ones are: a thin binder gets
//  small rings, a fat one gets the big ones. The gutter is the other half of
//  that read — on a folding device it deepens as the hinge closes, so the
//  crease between the two panels lands in the binder's own shadow instead of
//  cutting a line through the artwork (see BinderStage).
//

import RealityKit
import UIKit
import simd

/// Handles to the binder's mutable parts (stack slabs resize on every flip,
/// rings resize with them, the gutter tracks the fold).
@MainActor
struct BinderRig {
    let root: Entity
    let leftCover: ModelEntity
    let rightCover: ModelEntity
    let spine: ModelEntity
    let leftStack: ModelEntity
    let rightStack: ModelEntity
    /// Shadowed valley between the two page stacks.
    let gutter: ModelEntity
    /// Metal plate the ring mechanism is riveted to.
    let ringPlate: ModelEntity
    /// Parent of the three ring arcs; rebuilt when the binder's thickness
    /// calls for a different ring size.
    let rings: Entity
}

@MainActor
enum BinderBuilder3D {
    static let coverWidth: Float = 0.26
    static let coverDepth: Float = 0.32
    static let coverThickness: Float = 0.008
    static let pageStackWidth: Float = 0.24
    static let pageStackDepth: Float = 0.30
    /// Thickness of one vinyl sheet in the stack (chunky on purpose so a
    /// single flip visibly moves material between the stacks).
    static let sheetThickness: Float = 0.0024
    /// Inner x edge of both page stacks (small gap for the spine/rings).
    static let stackInnerX: Float = 0.005

    // MARK: Hardware

    /// Gauge of the ring wire (m).
    static let ringWire: Float = 0.0022
    /// Ring radii, floor and ceiling. The floor is a slim "1 inch" binder;
    /// the ceiling has room for the fattest stack we build (40 sheets =
    /// 0.096 m plus the clearance below) without clamping.
    static let ringRadiusRange: ClosedRange<Float> = 0.012...0.11
    /// How far the ring arc's apex clears the top of the page stack (m).
    static let ringClearance: Float = 0.008
    /// Where along the spine the three rings sit (m from the binder's middle).
    static let ringOffsetsZ: [Float] = [-0.095, 0, 0.095]
    /// Segments per ring arc — enough that 2 mm wire reads as round.
    static let ringSegments = 18
    /// Arc each ring sweeps: a touch past a half circle at both ends, so the
    /// wire disappears into the plate rather than stopping in mid-air.
    static let ringArc: ClosedRange<Float> = Float(-0.22)...(Float.pi + 0.22)

    /// Ring size currently built. Rebuilding 54 little boxes on every page
    /// flip would be wasteful, so `updateRings` only does it when the binder's
    /// thickness has actually moved the size.
    private static var builtRingRadius: Float = 0
    /// Rebuild threshold (m).
    private static let ringRebuildTolerance: Float = 0.0015

    /// World Y of the TOP surface of a stack holding `sheets` sheets.
    static func stackTopY(sheets: Int) -> Float {
        coverThickness + Float(max(0, sheets)) * sheetThickness
    }

    /// Ring radius for a binder whose thickest side holds `sheets` sheets.
    /// The arc apex sits at `coverThickness + 0.002 + radius` while the stack
    /// top is at `coverThickness + stack`, so the radius has to be the stack
    /// height itself plus a clearance — anything less and the wire sinks into
    /// the paper on thick binders.
    static func ringRadius(sheets: Int) -> Float {
        let stack = Float(max(0, sheets)) * sheetThickness
        return min(max(stack + ringClearance, ringRadiusRange.lowerBound), ringRadiusRange.upperBound)
    }

    static func makeOpenBinder() -> BinderRig {
        let root = Entity()
        root.name = "BinderRoot"

        var leather = PhysicallyBasedMaterial()
        leather.baseColor = .init(tint: .init(red: 0.23, green: 0.10, blue: 0.06, alpha: 1))
        leather.roughness = 0.62
        leather.metallic = 0.0

        let coverMesh = MeshResource.generateBox(
            width: coverWidth,
            height: coverThickness,
            depth: coverDepth,
            cornerRadius: 0.004
        )
        let leftCover = ModelEntity(mesh: coverMesh, materials: [leather])
        leftCover.name = "LeftCover"
        leftCover.position = SIMD3<Float>(-coverWidth / 2 - 0.005, coverThickness / 2, 0)

        let rightCover = ModelEntity(mesh: coverMesh, materials: [leather])
        rightCover.name = "RightCover"
        rightCover.position = SIMD3<Float>(coverWidth / 2 + 0.005, coverThickness / 2, 0)

        // Stitched border on each cover — four thin raised bars inset from
        // the edge. Cheap, and it's the detail that stops the covers reading
        // as two plain slabs.
        leftCover.addChild(stitching())
        rightCover.addChild(stitching())

        // The spine strip bridges the two covers, filling the gap between
        // them exactly so nothing overlaps (and nothing z-fights).
        let spineWidth = 2 * stackInnerX + 0.002
        let spine = ModelEntity(
            mesh: .generateBox(
                width: spineWidth, height: coverThickness, depth: coverDepth, cornerRadius: 0.002),
            materials: [leather]
        )
        spine.name = "Spine"
        spine.position = SIMD3<Float>(0, coverThickness / 2, 0)

        // The gutter: the shadowed valley you see down the middle of any open
        // binder, sitting just proud of the covers and between the stacks.
        // `setGutter` darkens and widens it as a folding device closes.
        let gutter = ModelEntity(
            mesh: .generateBox(
                width: BinderStage.baseGutterWidth, height: 0.0008,
                depth: coverDepth - 0.01, cornerRadius: 0.0003),
            materials: [gutterMaterial(depth: 0)]
        )
        gutter.name = "Gutter"
        gutter.position = SIMD3<Float>(0, coverThickness + 0.0004, 0)

        // Ring mechanism: a steel plate down the spine carrying three rings.
        let ringPlate = ModelEntity(
            mesh: .generateBox(
                width: 0.024, height: 0.0016, depth: pageStackDepth, cornerRadius: 0.0006),
            materials: [metalMaterial()]
        )
        ringPlate.name = "RingPlate"
        ringPlate.position = SIMD3<Float>(0, coverThickness + 0.0012, 0)

        let rings = Entity()
        rings.name = "Rings"
        rings.position = SIMD3<Float>(0, coverThickness + 0.002, 0)

        // Stacks start empty; BinderFlipController calls updateStacks on
        // every (re)bind with the real sheet distribution.
        let leftStack = ModelEntity()
        leftStack.name = "LeftPageStack"
        let rightStack = ModelEntity()
        rightStack.name = "RightPageStack"

        root.addChild(leftCover)
        root.addChild(rightCover)
        root.addChild(spine)
        root.addChild(gutter)
        root.addChild(ringPlate)
        root.addChild(rings)
        root.addChild(leftStack)
        root.addChild(rightStack)

        let rig = BinderRig(
            root: root,
            leftCover: leftCover,
            rightCover: rightCover,
            spine: spine,
            leftStack: leftStack,
            rightStack: rightStack,
            gutter: gutter,
            ringPlate: ringPlate,
            rings: rings
        )
        builtRingRadius = 0
        updateRings(rig: rig, sheets: 0)
        return rig
    }

    // MARK: Materials

    private static func metalMaterial() -> PhysicallyBasedMaterial {
        var metal = PhysicallyBasedMaterial()
        metal.baseColor = .init(tint: .init(white: 0.80, alpha: 1))
        metal.roughness = 0.22
        metal.metallic = 1.0
        return metal
    }

    /// Gutter shade. `depth` 0 is the everyday valley; 1 is the deep shadow
    /// the binder wears when a folding device has closed around its spine.
    private static func gutterMaterial(depth: Float) -> PhysicallyBasedMaterial {
        let t = min(max(depth, 0), 1)
        let value = CGFloat(0.10 - 0.08 * t)
        var shade = PhysicallyBasedMaterial()
        shade.baseColor = .init(tint: .init(white: value, alpha: 1))
        shade.roughness = 0.95
        shade.metallic = 0.0
        return shade
    }

    /// Four thin bars inset from a cover's edge, read as stitching.
    private static func stitching() -> Entity {
        var thread = PhysicallyBasedMaterial()
        thread.baseColor = .init(tint: .init(red: 0.52, green: 0.34, blue: 0.22, alpha: 1))
        thread.roughness = 0.75
        thread.metallic = 0.0

        let inset: Float = 0.009
        let gauge: Float = 0.0012
        let spanX = coverWidth - 2 * inset
        let spanZ = coverDepth - 2 * inset
        let y = coverThickness / 2 + gauge / 4

        let frame = Entity()
        frame.name = "CoverStitching"
        func bar(width: Float, depth: Float, at position: SIMD3<Float>) {
            let entity = ModelEntity(
                mesh: .generateBox(width: width, height: gauge, depth: depth, cornerRadius: gauge * 0.45),
                materials: [thread]
            )
            entity.position = position
            frame.addChild(entity)
        }
        bar(width: spanX, depth: gauge, at: SIMD3<Float>(0, y, -spanZ / 2))
        bar(width: spanX, depth: gauge, at: SIMD3<Float>(0, y, spanZ / 2))
        bar(width: gauge, depth: spanZ, at: SIMD3<Float>(-spanX / 2, y, 0))
        bar(width: gauge, depth: spanZ, at: SIMD3<Float>(spanX / 2, y, 0))
        return frame
    }

    // MARK: Rings

    /// Rebuilds the three ring arcs for the binder's current thickness, if
    /// that thickness has moved enough to matter.
    static func updateRings(rig: BinderRig, sheets: Int) {
        let radius = ringRadius(sheets: sheets)
        guard abs(radius - builtRingRadius) > ringRebuildTolerance else { return }
        builtRingRadius = radius
        for child in Array(rig.rings.children) { child.removeFromParent() }
        let metal = metalMaterial()
        for offset in ringOffsetsZ {
            let ring = makeRing(radius: radius, material: metal)
            ring.position = SIMD3<Float>(0, 0, offset)
            rig.rings.addChild(ring)
        }
    }

    /// One ring arc, approximated by short rounded bars laid tangent to the
    /// circle in the x/y plane (so the arc rises out of the spine and over
    /// the inner edge of the pages, the way a real ring threads the holes).
    private static func makeRing(radius: Float, material: PhysicallyBasedMaterial) -> Entity {
        let ring = Entity()
        ring.name = "Ring"
        let start = ringArc.lowerBound
        let span = ringArc.upperBound - ringArc.lowerBound
        let step = span / Float(ringSegments)
        // Overlap neighbours slightly so the arc has no visible gaps.
        let length = 2 * radius * sin(step / 2) * 1.12
        let mesh = MeshResource.generateBox(
            width: length, height: ringWire, depth: ringWire, cornerRadius: ringWire * 0.45)
        for index in 0..<ringSegments {
            let mid = start + step * (Float(index) + 0.5)
            let segment = ModelEntity(mesh: mesh, materials: [material])
            segment.position = SIMD3<Float>(radius * cos(mid), radius * sin(mid), 0)
            // Local +x is the bar's length; turn it to the circle's tangent.
            segment.orientation = simd_quatf(angle: mid + .pi / 2, axis: SIMD3<Float>(0, 0, 1))
            ring.addChild(segment)
        }
        return ring
    }

    // MARK: Gutter

    /// Sets how the gutter reads: `depth` 0 for a flat display, rising toward
    /// 1 as a folding device closes, and `width` the world span it covers.
    static func setGutter(rig: BinderRig, depth: Float, width: Float) {
        let clamped = min(max(width, 0.004), 0.12)
        rig.gutter.model = ModelComponent(
            mesh: .generateBox(
                width: clamped, height: 0.0008,
                depth: coverDepth - 0.01, cornerRadius: 0.0003),
            materials: [gutterMaterial(depth: depth)]
        )
    }

    /// Rebuilds both stack slabs for the given sheet distribution. A side
    /// with zero sheets shows no slab (you'd see the inside of the cover).
    static func updateStacks(rig: BinderRig, leftSheets: Int, rightSheets: Int) {
        updateStack(rig.leftStack, sheets: leftSheets, centerX: -(stackInnerX + pageStackWidth / 2))
        updateStack(rig.rightStack, sheets: rightSheets, centerX: stackInnerX + pageStackWidth / 2)
        // Ring size follows the binder's thickness, the way a real one does.
        updateRings(rig: rig, sheets: max(leftSheets, rightSheets))
    }

    private static func updateStack(_ slab: ModelEntity, sheets: Int, centerX: Float) {
        guard sheets > 0 else {
            slab.isEnabled = false
            return
        }
        var paper = PhysicallyBasedMaterial()
        paper.baseColor = .init(tint: .init(white: 0.93, alpha: 1))
        paper.roughness = 0.9
        paper.metallic = 0.0

        let thickness = Float(sheets) * sheetThickness
        slab.model = ModelComponent(
            mesh: .generateBox(
                width: pageStackWidth,
                height: thickness,
                depth: pageStackDepth,
                cornerRadius: min(0.002, thickness / 2)
            ),
            materials: [paper]
        )
        slab.position = SIMD3<Float>(centerX, coverThickness + thickness / 2, 0)
        slab.isEnabled = true
    }
}
