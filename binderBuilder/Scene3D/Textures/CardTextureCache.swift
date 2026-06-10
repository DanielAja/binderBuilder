//
//  CardTextureCache.swift
//  binderBuilder
//
//  Bridges the ImageCache (CGImage source of truth, shared with the 2D UI) to
//  RealityKit TextureResources for the 3D card surfaces. An LRU keyed by
//  CardRef keeps at most `capacity` GPU textures resident (~2.6 MB each at
//  600x825 BGRA8 + mips, so ~125 MB at 48). In-flight loads are deduplicated
//  so the same card requested by several pockets/spreads only decodes once.
//
//  Synchronous `cached(_:)` returns an already-resident texture (or nil) so
//  the placement coordinator can pose a card immediately; `load(_:imageBase:)`
//  fetches + uploads off the cached path and is awaited by callers that want
//  the real art.
//

import OSLog
import RealityKit
import simd

@MainActor
final class CardTextureCache {
    private static let log = Logger(subsystem: "com.aja.binderBuilder", category: "CardTextureCache")

    let imageCache: ImageCache
    let quality: ImageQuality
    private let capacity: Int

    private var lru: [CardRef: TextureResource] = [:]
    /// Most-recently-used last.
    private var order: [CardRef] = []
    private var inFlight: [CardRef: Task<TextureResource, Error>] = [:]

    /// Shared placeholder shown while art loads or when a card has no image.
    private(set) lazy var placeholder: TextureResource = Self.makePlaceholder()

    init(imageCache: ImageCache, quality: ImageQuality = .high, capacity: Int = 48) {
        self.imageCache = imageCache
        self.quality = quality
        self.capacity = capacity
    }

    /// A resident texture for `ref`, or nil if it hasn't been loaded yet.
    /// Marks it most-recently-used.
    func cached(_ ref: CardRef) -> TextureResource? {
        guard let texture = lru[ref] else { return nil }
        touch(ref)
        return texture
    }

    /// Loads (or returns the resident) texture for a card. Deduplicates
    /// concurrent requests for the same ref.
    func load(_ ref: CardRef, imageBase: String?, pinned: Bool = false) async throws -> TextureResource {
        if let texture = cached(ref) { return texture }
        if let task = inFlight[ref] { return try await task.value }

        let task = Task { [imageCache, quality] in
            let image = try await imageCache.image(
                for: ref.cardID, imageBase: imageBase, quality: quality, pinned: pinned
            )
            return try await TextureResource(image: image, options: .init(semantic: .color))
        }
        inFlight[ref] = task
        defer { inFlight[ref] = nil }
        let texture = try await task.value
        insert(ref, texture)
        return texture
    }

    // MARK: LRU bookkeeping

    private func insert(_ ref: CardRef, _ texture: TextureResource) {
        lru[ref] = texture
        touch(ref)
        while order.count > capacity {
            let evicted = order.removeFirst()
            lru[evicted] = nil
        }
    }

    private func touch(_ ref: CardRef) {
        if let existing = order.firstIndex(of: ref) { order.remove(at: existing) }
        order.append(ref)
    }

    var residentCount: Int { lru.count }

    private static func makePlaceholder() -> TextureResource {
        (try? TextureResource(image: PlaceholderArt.cardBack, options: .init(semantic: .color)))
            ?? (try! TextureResource(image: PlaceholderArt.loading, options: .init(semantic: .color)))
    }
}
