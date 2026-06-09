//
//  BinderBuilder3D.swift
//  binderBuilder
//
//  Procedural placeholder for the open binder: two leather-ish cover halves,
//  a simple spine, and two static white page-stack slabs, lying open on the
//  ground (XZ plane, Y up). Replaced by Blender assets in a later phase;
//  dimensions match the plan (binder ~0.32 x 0.26 x 0.05 m closed, so each
//  cover half is ~0.26 wide x 0.32 deep when open).
//

import RealityKit
import UIKit
import simd

@MainActor
enum BinderBuilder3D {
    static let coverWidth: Float = 0.26
    static let coverDepth: Float = 0.32
    static let coverThickness: Float = 0.008
    static let pageStackWidth: Float = 0.24
    static let pageStackDepth: Float = 0.30
    static let pageStackThickness: Float = 0.006

    /// Y of the top surface of each page stack — where the deformable page rests.
    static var pageRestHeight: Float { coverThickness + pageStackThickness }

    static func makeOpenBinder() -> Entity {
        let root = Entity()
        root.name = "BinderRoot"

        var leather = PhysicallyBasedMaterial()
        leather.baseColor = .init(tint: .init(red: 0.23, green: 0.10, blue: 0.06, alpha: 1))
        leather.roughness = 0.62
        leather.metallic = 0.0

        var paper = PhysicallyBasedMaterial()
        paper.baseColor = .init(tint: .init(white: 0.93, alpha: 1))
        paper.roughness = 0.9
        paper.metallic = 0.0

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

        let stackMesh = MeshResource.generateBox(
            width: pageStackWidth,
            height: pageStackThickness,
            depth: pageStackDepth,
            cornerRadius: 0.002
        )
        let stackY = coverThickness + pageStackThickness / 2
        let leftStack = ModelEntity(mesh: stackMesh, materials: [paper])
        leftStack.name = "LeftPageStack"
        leftStack.position = SIMD3<Float>(-pageStackWidth / 2 - 0.01, stackY, 0)

        let rightStack = ModelEntity(mesh: stackMesh, materials: [paper])
        rightStack.name = "RightPageStack"
        rightStack.position = SIMD3<Float>(pageStackWidth / 2 + 0.01, stackY, 0)

        root.addChild(leftCover)
        root.addChild(rightCover)
        root.addChild(spine)
        root.addChild(leftStack)
        root.addChild(rightStack)
        return root
    }
}
