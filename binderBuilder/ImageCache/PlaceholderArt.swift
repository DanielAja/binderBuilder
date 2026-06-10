//
//  PlaceholderArt.swift
//  binderBuilder
//
//  Original placeholder artwork drawn with CoreGraphics at runtime. No
//  Pokemon imagery ships in (or is drawn by) the binary: the card back is a
//  plain deep-navy field with a thin double border and a centered
//  diamond-and-ring motif.
//

import CoreGraphics
import Foundation

nonisolated enum PlaceholderArt {
    /// Matches the CDN's high-quality card size (600x825).
    static let pixelSize = (width: 600, height: 825)

    /// The original-art card back, rendered once and cached for the process
    /// lifetime. Shown for cards with no CDN image.
    static let cardBack: CGImage = renderCardBack()

    /// Flat light-gray variant shown while a real image is downloading.
    static let loading: CGImage = renderLoading()

    // MARK: - Rendering

    private static func makeContext() -> CGContext? {
        CGContext(
            data: nil,
            width: pixelSize.width,
            height: pixelSize.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// 1x1 opaque fallback if bitmap-context creation ever fails (it should
    /// not on any supported device).
    private static func fallbackPixel() -> CGImage {
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context.makeImage()!
    }

    private static func renderCardBack() -> CGImage {
        guard let context = makeContext() else { return fallbackPixel() }
        let width = CGFloat(pixelSize.width)
        let height = CGFloat(pixelSize.height)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let center = CGPoint(x: width / 2, y: height / 2)

        let navy = CGColor(red: 0.07, green: 0.10, blue: 0.24, alpha: 1)
        let navyLight = CGColor(red: 0.12, green: 0.17, blue: 0.36, alpha: 1)
        let gold = CGColor(red: 0.79, green: 0.69, blue: 0.45, alpha: 1)
        let goldDim = CGColor(red: 0.55, green: 0.48, blue: 0.32, alpha: 1)

        // Deep navy field.
        context.setFillColor(navy)
        context.fill(bounds)

        // Thin double border.
        context.setStrokeColor(gold)
        context.setLineWidth(5)
        context.stroke(bounds.insetBy(dx: 20, dy: 20))
        context.setStrokeColor(goldDim)
        context.setLineWidth(2)
        context.stroke(bounds.insetBy(dx: 34, dy: 34))

        // Centered ring.
        let ringRadius: CGFloat = 165
        context.setStrokeColor(goldDim)
        context.setLineWidth(8)
        context.strokeEllipse(in: CGRect(
            x: center.x - ringRadius, y: center.y - ringRadius,
            width: ringRadius * 2, height: ringRadius * 2))

        // Diamond inside the ring.
        func diamondPath(radius: CGFloat) -> CGPath {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: center.x, y: center.y + radius))
            path.addLine(to: CGPoint(x: center.x + radius, y: center.y))
            path.addLine(to: CGPoint(x: center.x, y: center.y - radius))
            path.addLine(to: CGPoint(x: center.x - radius, y: center.y))
            path.closeSubpath()
            return path
        }
        context.setFillColor(navyLight)
        context.addPath(diamondPath(radius: 118))
        context.fillPath()
        context.setStrokeColor(gold)
        context.setLineWidth(4)
        context.addPath(diamondPath(radius: 118))
        context.strokePath()
        context.setStrokeColor(goldDim)
        context.setLineWidth(2)
        context.addPath(diamondPath(radius: 64))
        context.strokePath()

        // Tiny center dot to anchor the motif.
        context.setFillColor(gold)
        context.fillEllipse(in: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14))

        return context.makeImage() ?? fallbackPixel()
    }

    private static func renderLoading() -> CGImage {
        guard let context = makeContext() else { return fallbackPixel() }
        let bounds = CGRect(x: 0, y: 0, width: pixelSize.width, height: pixelSize.height)
        context.setFillColor(CGColor(red: 0.88, green: 0.88, blue: 0.90, alpha: 1))
        context.fill(bounds)
        return context.makeImage() ?? fallbackPixel()
    }
}
