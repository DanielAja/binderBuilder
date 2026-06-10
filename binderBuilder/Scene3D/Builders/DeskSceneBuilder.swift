//
//  DeskSceneBuilder.swift
//  binderBuilder
//
//  The "setting" the open binder lives in: a wooden desk the binder rests on,
//  a soft back wall so the scene isn't a void, a contact shadow grounding the
//  binder, and a few tasteful background props (a closed binder + a deck box).
//  Returned as one entity parented under the binder root so it shows/hides with
//  the binder (the shelf scene has its own setting).
//

import RealityKit
import UIKit
import simd

@MainActor
enum DeskSceneBuilder {
    /// Desk top sits at world y = 0 (the binder lies on it).
    static func build() -> Entity {
        let root = Entity()
        root.name = "BinderEnvironment"

        // Wooden desk top (top surface at y = 0; extends toward the camera and
        // back to the wall).
        var wood = PhysicallyBasedMaterial()
        if let grain = makeWoodTexture() {
            wood.baseColor = .init(tint: .white, texture: .init(grain))
        } else {
            wood.baseColor = .init(tint: UIColor(red: 0.52, green: 0.34, blue: 0.19, alpha: 1))
        }
        wood.roughness = 0.55
        wood.metallic = 0.0
        let desk = ModelEntity(
            mesh: .generateBox(width: 1.8, height: 0.06, depth: 1.2, cornerRadius: 0.012),
            materials: [wood])
        desk.name = "Desk"
        desk.position = SIMD3<Float>(0, -0.03, 0.12)
        root.addChild(desk)

        // Soft back wall (warm neutral) rising behind the desk.
        var wallMat = PhysicallyBasedMaterial()
        wallMat.baseColor = .init(tint: UIColor(red: 0.46, green: 0.43, blue: 0.50, alpha: 1))
        wallMat.roughness = 0.95
        wallMat.metallic = 0.0
        let wall = ModelEntity(mesh: .generatePlane(width: 4.0, height: 2.4), materials: [wallMat])
        wall.name = "BackWall"
        wall.position = SIMD3<Float>(0, 0.9, -0.62)
        root.addChild(wall)

        // Contact shadow under the binder (unlit soft ellipse just above desk).
        if let shadow = makeContactShadow() {
            shadow.position = SIMD3<Float>(0, 0.002, 0)
            root.addChild(shadow)
        }

        // Background props (small, at the back corners, never occluding the binder).
        root.addChild(makeDeckBox(at: SIMD3<Float>(0.46, 0.045, -0.32), color:
            UIColor(red: 0.12, green: 0.34, blue: 0.55, alpha: 1), yaw: 0.3))
        root.addChild(makeDeckBox(at: SIMD3<Float>(0.55, 0.045, -0.30), color:
            UIColor(red: 0.62, green: 0.16, blue: 0.18, alpha: 1), yaw: -0.2))

        return root
    }

    private static func makeDeckBox(at position: SIMD3<Float>, color: UIColor, yaw: Float) -> Entity {
        var box = PhysicallyBasedMaterial()
        box.baseColor = .init(tint: color)
        box.roughness = 0.4
        let e = ModelEntity(mesh: .generateBox(width: 0.072, height: 0.09, depth: 0.052, cornerRadius: 0.004),
                            materials: [box])
        e.name = "DeckBox"
        e.position = position
        e.orientation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        return e
    }

    /// Procedural warm wood: horizontal planks with subtle vertical grain.
    private static func makeWoodTexture() -> TextureResource? {
        let w = 512, h = 320
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(UIColor(red: 0.5, green: 0.33, blue: 0.19, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Fine vertical grain streaks.
        for x in stride(from: 0, to: w, by: 2) {
            let n = sin(Double(x) * 0.21) * 0.5 + sin(Double(x) * 0.07) * 0.5
            let shade = 0.5 + n * 0.06
            ctx.setFillColor(UIColor(red: shade, green: shade * 0.66, blue: shade * 0.38, alpha: 1).cgColor)
            ctx.fill(CGRect(x: x, y: 0, width: 2, height: h))
        }
        // A few darker plank seams.
        ctx.setFillColor(UIColor(red: 0.30, green: 0.19, blue: 0.10, alpha: 0.6).cgColor)
        for row in 1..<4 { ctx.fill(CGRect(x: 0, y: row * h / 4, width: w, height: 2)) }
        guard let image = ctx.makeImage() else { return nil }
        return try? TextureResource(image: image, options: .init(semantic: .color))
    }

    private static func makeContactShadow() -> ModelEntity? {
        let size = 256
        guard let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let colors = [UIColor(white: 0, alpha: 0.38).cgColor,
                      UIColor(white: 0, alpha: 0.30).cgColor,
                      UIColor(white: 0, alpha: 0).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors, locations: [0, 0.55, 1]) else { return nil }
        let c = CGFloat(size) / 2
        ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: c, y: c), startRadius: 0,
                               endCenter: CGPoint(x: c, y: c), endRadius: c, options: [])
        guard let image = ctx.makeImage(),
              let texture = try? TextureResource(image: image, options: .init(semantic: .color)) else { return nil }
        var mat = UnlitMaterial()
        mat.color = .init(tint: .white, texture: .init(texture))
        mat.blending = .transparent(opacity: .init(floatLiteral: 1.0))
        mat.opacityThreshold = 0
        // Wider than the binder so the soft edge falls off past it.
        let plane = ModelEntity(mesh: .generatePlane(width: 0.62, depth: 0.42), materials: [mat])
        plane.name = "ContactShadow"
        return plane
    }
}
