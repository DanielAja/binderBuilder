//
//  ScannerTests.swift
//  binderBuilderTests
//
//  dHash bit layout / decoding, the nearest-card matcher ranking (on and off
//  the main actor), and the reticle/crop mapping under an aspect-fill preview.
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

    @Test func matcherRanksClosestCardFirst() {
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

    @Test func matcherKeepsBestOrientationPerCard() {
        let matcher = CardHashMatcher(entries: [
            .init(cardID: "a", dhash: 0xFFFF_FFFF_FFFF_FFFF), // far
            .init(cardID: "a", dhash: 0x0000_0000_0000_0000), // exact (other orientation)
        ])
        let matches = matcher.match(0, limit: 5)
        #expect(matches.count == 1)
        #expect(matches.first?.distance == 0)
    }

    /// The index is immutable, so the live scanner runs the Hamming scan off
    /// the main thread — same shortlist, no UI stutter.
    @Test func matcherIsIdenticalOffTheMainActor() async {
        let matcher = CardHashMatcher(entries: [
            .init(cardID: "a", dhash: 0x0000_0000_0000_0000),
            .init(cardID: "b", dhash: 0x0000_0000_0000_00FF),
            .init(cardID: "c", dhash: 0xFFFF_FFFF_FFFF_FFFF),
        ])
        let query: UInt64 = 0x0000_0000_0000_0003
        let onMain = await MainActor.run { matcher.match(query, limit: 3) }
        let offMain = await Task.detached { matcher.match(query, limit: 3) }.value
        #expect(onMain == offMain)
        #expect(offMain.map(\.cardID) == ["a", "b", "c"])
    }

    // MARK: - Reticle / crop alignment

    /// What the camera delivers, portrait (the .hd1280x720 preset rotated).
    private static let frame = CameraScanner.frameSize

    /// Point sizes covering the three aspect ratios the preview has to fill.
    private static let screens: [(name: String, size: CGSize)] = [
        ("iPhone SE", CGSize(width: 375, height: 667)),
        ("iPhone 16 Pro Max", CGSize(width: 440, height: 956)),
        ("iPad 11-inch", CGSize(width: 1032, height: 1376)),
    ]

    @Test func reticleIsExactlyTheProjectionOfTheAnalyzedCrop() {
        for screen in Self.screens {
            let crop = SingleCardScanner.cropRect(frameSize: Self.frame, viewSize: screen.size)
            let reticle = SingleCardScanner.visibleCropRect(frameSize: Self.frame, viewSize: screen.size)
            #expect(reticle == SingleCardScanner.project(crop, frameSize: Self.frame,
                                                         viewSize: screen.size),
                    "\(screen.name)")
        }
    }

    @Test func reticleKeepsCardAspectAndFitsEveryScreen() {
        for screen in Self.screens {
            let r = SingleCardScanner.visibleCropRect(frameSize: Self.frame, viewSize: screen.size)
            #expect(abs(r.width / r.height - SingleCardScanner.cardAspect) < 0.01, "\(screen.name)")
            // Fully on screen (aspect-fill clips the frame's long axis) …
            #expect(r.minX > 0 && r.minY > 0, "\(screen.name)")
            #expect(r.maxX < screen.size.width && r.maxY < screen.size.height, "\(screen.name)")
            // … centered on the preview, and large enough to aim with.
            #expect(abs(r.midX - screen.size.width / 2) < 0.001, "\(screen.name)")
            #expect(abs(r.midY - screen.size.height / 2) < 0.001, "\(screen.name)")
            #expect(r.width > screen.size.width * 0.5, "\(screen.name)")
        }
    }

    @Test func analyzedCropStaysInsideTheCameraFrame() {
        for screen in Self.screens {
            let c = SingleCardScanner.cropRect(frameSize: Self.frame, viewSize: screen.size)
            #expect(c.minX >= 0 && c.minY >= 0, "\(screen.name)")
            #expect(c.maxX <= Self.frame.width && c.maxY <= Self.frame.height, "\(screen.name)")
            #expect(abs(c.midX - Self.frame.width / 2) < 0.001, "\(screen.name)")
            #expect(abs(c.midY - Self.frame.height / 2) < 0.001, "\(screen.name)")
        }
    }

    /// No preview (a chosen photo) — crop the frame itself, as before.
    @Test func chosenPhotoCropIgnoresPreviewGeometry() {
        let rect = SingleCardScanner.cropRect(frameSize: CGSize(width: 300, height: 400))
        #expect(abs(rect.height - 400 * 0.82) < 0.001)
        #expect(abs(rect.width - 400 * 0.82 * SingleCardScanner.cardAspect) < 0.001)
        #expect(abs(rect.midX - 150) < 0.001)
        #expect(abs(rect.midY - 200) < 0.001)
    }

    @Test func aspectFillScalesToCoverAndCentersTheFrame() {
        // A 720×1280 frame in a 440×956 view covers by height: scale 956/1280,
        // so the frame's full width lands 48.9 pt off each side.
        let full = CGRect(origin: .zero, size: Self.frame)
        let view = CGSize(width: 440, height: 956)
        let projected = SingleCardScanner.project(full, frameSize: Self.frame, viewSize: view)
        #expect(abs(projected.height - 956) < 0.001)
        #expect(abs(projected.width - 720 * (956 / 1280)) < 0.001)
        #expect(abs(projected.midX - 220) < 0.001)
        #expect(projected.minX < 0)
    }
}
