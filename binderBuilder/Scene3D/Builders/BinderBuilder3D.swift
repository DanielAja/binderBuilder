//
//  BinderBuilder3D.swift
//  binderBuilder
//
//  Procedural placeholder for the open binder: two leather-ish cover halves,
//  a simple spine, and two static page-stack slabs whose thicknesses track
//  how many sheets currently rest on each side of the open spread. Replaced
//  by Blender assets in a later phase; dimensions match the plan (binder
//  ~0.32 x 0.26 x 0.05 m closed, so each cover half is ~0.26 wide x 0.32
//  deep when open).
//

import RealityKit
import UIKit
import simd

/// Handles to the binder's mutable parts (stack slabs resize on every flip).
@MainActor
struct BinderRig {
    let root: Entity
    let leftCover: ModelEntity
    let rightCover: ModelEntity
    let spine: ModelEntity
    let leftStack: ModelEntity
    let rightStack: ModelEntity
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

    /// World Y of the TOP surface of a stack holding `sheets` sheets.
    static func stackTopY(sheets: Int) -> Float {
        coverThickness + Float(max(0, sheets)) * sheetThickness
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

        let spine = ModelEntity(
            mesh: .generateBox(width: 0.03, height: coverThickness + 0.006, depth: coverDepth, cornerRadius: 0.004),
            materials: [leather]
        )
        spine.name = "Spine"
        spine.position = SIMD3<Float>(0, (coverThickness + 0.006) / 2, 0)

        // Stacks start empty; BinderFlipController calls updateStacks on
        // every (re)bind with the real sheet distribution.
        let leftStack = ModelEntity()
        leftStack.name = "LeftPageStack"
        let rightStack = ModelEntity()
        rightStack.name = "RightPageStack"

        root.addChild(leftCover)
        root.addChild(rightCover)
        root.addChild(spine)
        root.addChild(leftStack)
        root.addChild(rightStack)
        return BinderRig(
            root: root,
            leftCover: leftCover,
            rightCover: rightCover,
            spine: spine,
            leftStack: leftStack,
            rightStack: rightStack
        )
    }

    /// Rebuilds both stack slabs for the given sheet distribution. A side
    /// with zero sheets shows no slab (you'd see the inside of the cover).
    static func updateStacks(rig: BinderRig, leftSheets: Int, rightSheets: Int) {
        updateStack(rig.leftStack, sheets: leftSheets, centerX: -(stackInnerX + pageStackWidth / 2))
        updateStack(rig.rightStack, sheets: rightSheets, centerX: stackInnerX + pageStackWidth / 2)
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
