//
//  CardTextureCache.swift
//  binderBuilder
//
//  Bridges the ImageCache (CGImage source of truth, shared with the 2D UI) to
//  RealityKit TextureResources for the 3D card surfaces. An LRU keyed by
//  card ID keeps at most `capacity` GPU textures resident (~2.6 MB each at
//  600x825 BGRA8 + mips, so ~125 MB at the default capacity of 48, halved to
//  24 on memory-constrained devices). In-flight loads are deduplicated so the
//  same card requested by several pockets/spreads only decodes once.
//
//  Keyed by card ID, not CardRef: the art is fetched by card ID alone (every
//  printing of a card shares one image — the variant is a shader treatment
//  on top), so keying by ref uploaded the SAME pixels once per variant, and
//  a normal + holo pair of one card held two identical textures resident
//  and evicted real neighbours to make room.
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

    private var lru: [String: TextureResource] = [:]
    /// Card IDs, most-recently-used last.
    private var order: [String] = []
    private var inFlight: [String: Task<TextureResource, Error>] = [:]

    /// Shared placeholder shown while art loads or when a card has no image.
    private(set) lazy var placeholder: TextureResource = Self.makePlaceholder()

    init(imageCache: ImageCache, quality: ImageQuality = .high, capacity: Int = CardTextureCache.defaultCapacity) {
        self.imageCache = imageCache
        self.quality = quality
        self.capacity = capacity
    }

    /// 48 resident textures (~125 MB at 600x825) normally; halved on
    /// memory-constrained devices (see `DeviceMemoryTier`) to reduce jetsam
    /// risk once RealityKit's own footprint is added. Overridable via `init`.
    nonisolated static var defaultCapacity: Int { DeviceMemoryTier.isConstrained ? 24 : 48 }

    /// A resident texture for `ref`, or nil if it hasn't been loaded yet.
    /// Marks it most-recently-used.
    func cached(_ ref: CardRef) -> TextureResource? {
        let key = ref.cardID
        guard let texture = lru[key] else { return nil }
        touch(key)
        return texture
    }

    /// Loads (or returns the resident) texture for a card. Deduplicates
    /// concurrent requests for the same card, whatever the variant.
    func load(_ ref: CardRef, imageBase: String?, pinned: Bool = false) async throws -> TextureResource {
        if let texture = cached(ref) { return texture }
        let key = ref.cardID
        if let task = inFlight[key] { return try await task.value }

        let task = Task { [imageCache, quality] in
            let image = try await imageCache.image(
                for: key, imageBase: imageBase, quality: quality, pinned: pinned
            )
            return try await TextureResource(image: image, options: .init(semantic: .color))
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let texture = try await task.value
        insert(key, texture)
        return texture
    }

    // MARK: LRU bookkeeping

    private func insert(_ key: String, _ texture: TextureResource) {
        lru[key] = texture
        touch(key)
        while order.count > capacity {
            let evicted = order.removeFirst()
            lru[evicted] = nil
        }
    }

    private func touch(_ key: String) {
        if let existing = order.firstIndex(of: key) { order.remove(at: existing) }
        order.append(key)
    }

    var residentCount: Int { lru.count }

    private static func makePlaceholder() -> TextureResource {
        guard let texture =
            (try? TextureResource(image: PlaceholderArt.cardBack, options: .init(semantic: .color)))
            ?? (try? TextureResource(image: PlaceholderArt.loading, options: .init(semantic: .color)))
        else {
            fatalError("Unable to create any placeholder card texture")
        }
        return texture
    }
}
