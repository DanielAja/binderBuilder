//
//  BinderScanPipeline.swift
//  binderBuilder
//
//  Turns a photo of one binder page side into nine per-slot results: split the
//  page into an inset 3x3 grid (the manual-grid fallback; robust and the basis
//  for a future VNDetectRectangles refinement), classify empty pockets by
//  luminance variance, dHash each occupied crop, and shortlist the closest
//  cards. A per-slot confidence review UI corrects the rest.
//

import CoreGraphics
import Foundation

struct ScanSlotResult: Identifiable, Sendable {
    let id: Int            // slot index 0...8
    var slotIndex: Int { id }
    let crop: CGImage?
    let isEmpty: Bool
    let matches: [CardMatch]
    /// The accepted match (top match by default; nil = empty/unknown). Editable.
    var chosen: CardMatch?
}

@MainActor
enum BinderScanPipeline {
    /// Fraction of each cell trimmed on every side to avoid sleeve seams.
    static let cellInset: CGFloat = 0.10
    /// Below this normalized luminance variance a pocket reads as empty.
    static let emptyVarianceThreshold: Double = 0.0025

    static func scan(page: CGImage, matcher: CardHashMatcher) -> [ScanSlotResult] {
        let width = CGFloat(page.width), height = CGFloat(page.height)
        let cellW = width / 3, cellH = height / 3
        var results: [ScanSlotResult] = []
        for row in 0..<3 {
            for col in 0..<3 {
                let slot = row * 3 + col
                let rect = CGRect(
                    x: CGFloat(col) * cellW + cellW * cellInset,
                    y: CGFloat(row) * cellH + cellH * cellInset,
                    width: cellW * (1 - 2 * cellInset),
                    height: cellH * (1 - 2 * cellInset)
                )
                guard let crop = page.cropping(to: rect) else {
                    results.append(ScanSlotResult(id: slot, crop: nil, isEmpty: true, matches: [], chosen: nil))
                    continue
                }
                let empty = luminanceVariance(crop) < emptyVarianceThreshold
                let matches = empty ? [] : matcher.match(PerceptualHash.dHash(crop), limit: 5)
                results.append(ScanSlotResult(
                    id: slot, crop: crop, isEmpty: empty, matches: matches, chosen: matches.first
                ))
            }
        }
        return results
    }

    /// Normalized (0...1) luminance variance via a small grayscale downscale.
    static func luminanceVariance(_ image: CGImage) -> Double {
        let n = 16
        var px = [UInt8](repeating: 0, count: n * n)
        guard let ctx = CGContext(
            data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 1 }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        let values = px.map { Double($0) / 255 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance
    }
}
