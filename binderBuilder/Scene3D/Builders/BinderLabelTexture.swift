//
//  BinderLabelTexture.swift
//  binderBuilder
//
//  CGContext-rendered name plaques for shelf binders: gold-ish text on dark
//  leather, horizontal for face-out covers and rotated for spine-out books.
//  Textures are tiny (256x64) and rebuilt only when the shelf refreshes.
//

import CoreGraphics
import RealityKit
import UIKit

@MainActor
enum BinderLabelTexture {
    /// Plaque aspect is 4:1 (256x64) — matches the plaque mesh in
    /// ShelfSceneBuilder.
    static let size = CGSize(width: 256, height: 64)

    /// nil when rendering fails (caller just skips the plaque).
    static func make(name: String, vertical: Bool = false) -> TextureResource? {
        let canvas = vertical ? CGSize(width: size.height, height: size.width) : size
        let renderer = UIGraphicsImageRenderer(size: canvas, format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            return format
        }())
        let image = renderer.image { context in
            let cg = context.cgContext
            UIColor(red: 0.11, green: 0.07, blue: 0.05, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: canvas))

            let text = name.isEmpty ? "Binder" : name
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 30, weight: .semibold),
                .foregroundColor: UIColor(red: 0.91, green: 0.75, blue: 0.38, alpha: 1),
            ]
            var rendered = text as NSString
            var textSize = rendered.size(withAttributes: attributes)
            // Truncate to fit rather than shrinking into illegibility.
            if textSize.width > size.width - 20 {
                var truncated = text
                while truncated.count > 1,
                      (truncated + "…" as NSString).size(withAttributes: attributes).width > size.width - 20 {
                    truncated.removeLast()
                }
                rendered = (truncated + "…") as NSString
                textSize = rendered.size(withAttributes: attributes)
            }

            if vertical {
                cg.translateBy(x: canvas.width / 2, y: canvas.height / 2)
                cg.rotate(by: -.pi / 2)
                cg.translateBy(x: -size.width / 2, y: -size.height / 2)
            }
            rendered.draw(
                at: CGPoint(x: (size.width - textSize.width) / 2,
                            y: (size.height - textSize.height) / 2),
                withAttributes: attributes)
        }
        guard let cg = image.cgImage else { return nil }
        return try? TextureResource(image: cg, options: .init(semantic: .color))
    }
}
