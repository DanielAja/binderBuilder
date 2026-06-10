//
//  PerceptualHash.swift
//  binderBuilder
//
//  On-device dHash matching the Python `imagehash.dhash(hash_size=8)` used by
//  tools/build_catalog.py to populate the bundled card_hash table, so a scanned
//  crop's hash is comparable to the stored BLOBs:
//   - grayscale, resize to 9x8,
//   - row-major horizontal gradient: bit = pixel[r][c+1] > pixel[r][c] (64 bits),
//   - packed MSB-first (np.packbits big-endian) into a UInt64 where the first
//     diff bit is the most-significant bit — the same order the 8-byte BLOB
//     decodes to when read big-endian.
//

import CoreGraphics

enum PerceptualHash {
    /// 64-bit dHash of an image (0 on failure).
    static func dHash(_ image: CGImage) -> UInt64 {
        let w = 9, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var hash: UInt64 = 0
        var bitIndex = 0
        for row in 0..<h {
            // CGContext buffer is bottom-up; PIL rows run top-down.
            let bufferRow = h - 1 - row
            for col in 0..<(w - 1) {
                let left = pixels[bufferRow * w + col]
                let right = pixels[bufferRow * w + col + 1]
                if right > left { hash |= (1 << (63 - bitIndex)) }
                bitIndex += 1
            }
        }
        return hash
    }

    /// Decodes an 8-byte stored dHash BLOB (np.packbits big-endian) to UInt64.
    static func decode(blob: [UInt8]) -> UInt64 {
        var value: UInt64 = 0
        for byte in blob.prefix(8) { value = (value << 8) | UInt64(byte) }
        return value
    }

    static func hamming(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }
}
