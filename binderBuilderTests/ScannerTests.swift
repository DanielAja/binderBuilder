//
//  ScannerTests.swift
//  binderBuilderTests
//
//  dHash bit layout / decoding and the nearest-card matcher ranking.
//

import Testing
import CoreGraphics
@testable import binderBuilder

@Suite struct ScannerTests {
    @Test func hammingCountsBitDifferences() {
        #expect(PerceptualHash.hamming(0, 0) == 0)
        #expect(PerceptualHash.hamming(0xFFFF_FFFF_FFFF_FFFF, 0) == 64)
        #expect(PerceptualHash.hamming(0b1011, 0b0001) == 2)
    }

    @Test func blobDecodesBigEndianMSBFirst() {
        // First byte is the most-significant -> first diff bit is bit 63.
        let blob: [UInt8] = [0x80, 0, 0, 0, 0, 0, 0, 0x01]
        let value = PerceptualHash.decode(blob: blob)
        #expect(value == (UInt64(1) << 63 | UInt64(1)))
    }

    @Test func dHashOfHorizontalGradientIsAllOnes() {
        // A left->right bright gradient: every pixel is brighter than the one
        // to its left, so every horizontal-gradient bit is 1 -> all 64 set.
        let w = 64, h = 64
        var px = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { px[y * w + x] = UInt8(x * 255 / (w - 1)) } }
        let ctx = CGContext(
            data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        let hash = PerceptualHash.dHash(ctx.makeImage()!)
        // Nearly every horizontal-gradient bit is set (a couple of edge
        // comparisons flatten under the 9x8 downscale interpolation).
        #expect(PerceptualHash.hamming(hash, 0xFFFF_FFFF_FFFF_FFFF) <= 4)
    }

    @MainActor @Test func matcherRanksClosestCardFirst() {
        let matcher = CardHashMatcher(entries: [
            .init(cardID: "a", dhash: 0x0000_0000_0000_0000),
            .init(cardID: "b", dhash: 0x0000_0000_0000_00FF), // 8 bits off
            .init(cardID: "c", dhash: 0xFFFF_FFFF_FFFF_FFFF), // 64 bits off
        ])
        let matches = matcher.match(0x0000_0000_0000_0001, limit: 3)
        #expect(matches.first?.cardID == "a")
        #expect(matches.first?.distance == 1)
        #expect(matches.map(\.cardID) == ["a", "b", "c"])
    }

    @MainActor @Test func matcherKeepsBestOrientationPerCard() {
        let matcher = CardHashMatcher(entries: [
            .init(cardID: "a", dhash: 0xFFFF_FFFF_FFFF_FFFF), // far
            .init(cardID: "a", dhash: 0x0000_0000_0000_0000), // exact (other orientation)
        ])
        let matches = matcher.match(0, limit: 5)
        #expect(matches.count == 1)
        #expect(matches.first?.distance == 0)
    }
}
