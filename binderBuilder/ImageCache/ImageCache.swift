//
//  ImageCache.swift
//  binderBuilder
//
//  Two-tier disk + memory cache for card images from the TCGdex CDN.
//
//  Disk layout: <root>/<quality>/<cardID>.webp where <root> is either the
//  pinned store (Application Support/CardImages, backup-excluded: owned and
//  slotted cards live forever) or the transient store (Caches/CardImages:
//  browse churn the system may purge).
//
//  Network behavior: in-flight requests are deduplicated per (card, quality);
//  failures are retried twice (0.5s / 2s) then negative-cached for 5 minutes;
//  HTTP 404 is negative-cached permanently for the process lifetime.
//

import CoreGraphics
import Foundation
import ImageIO
import os

/// CDN image quality tier. Raw values match the TCGdex asset filenames
/// (`low.webp` 245x337, `high.webp` 600x825).
nonisolated enum ImageQuality: String, Sendable, CaseIterable {
    case low
    case high
}

nonisolated enum ImageCacheError: Error, Equatable {
    /// The CDN answered 404 — this card has no image at this quality.
    /// Negative-cached permanently (until next launch).
    case notFound
    /// Download or decode kept failing; negative-cached for 5 minutes.
    case unavailable
}

actor ImageCache {
    private let session: URLSession
    private let pinnedRoot: URL
    private let cachesRoot: URL
    /// Backoff before retry 1 and retry 2. Injectable so tests don't sleep.
    private let retryDelays: [Duration]
    /// Clock seam for negative-cache expiry tests.
    private let now: @Sendable () -> Date

    private let memory = NSCache<NSString, CGImage>()
    private var inFlight: [String: Task<CGImage, Error>] = [:]
    private var permanentNegatives: Set<String> = []
    /// key -> time of the last exhausted-retries failure.
    private var transientNegatives: [String: Date] = [:]

    static let transientNegativeTTL: TimeInterval = 5 * 60

    private static let logger = Logger(subsystem: "com.aja.binderBuilder", category: "ImageCache")

    init(
        session: URLSession = .shared,
        pinnedRoot: URL,
        cachesRoot: URL,
        retryDelays: [Duration] = [.milliseconds(500), .seconds(2)],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.pinnedRoot = pinnedRoot
        self.cachesRoot = cachesRoot
        self.retryDelays = retryDelays
        self.now = now
        memory.totalCostLimit = 64 * 1024 * 1024  // ~64 MB of decoded pixels
        try? FileManager.default.createDirectory(at: pinnedRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cachesRoot, withIntermediateDirectories: true)
    }

    /// The production cache: Application Support/CardImages (backup-excluded)
    /// for pinned images, Caches/CardImages for transient ones.
    static func standard(session: URLSession = .shared) -> ImageCache {
        let fileManager = FileManager.default
        let support = (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        let caches = (try? fileManager.url(
            for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory

        var pinned = support.appendingPathComponent("CardImages", isDirectory: true)
        let transient = caches.appendingPathComponent("CardImages", isDirectory: true)

        // Pinned card images are re-downloadable; keep them out of backups.
        try? fileManager.createDirectory(at: pinned, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? pinned.setResourceValues(values)

        return ImageCache(session: session, pinnedRoot: pinned, cachesRoot: transient)
    }

    // MARK: - Fetch

    /// Returns the decoded image for a card, hitting (in order) the memory
    /// cache, the disk stores, then the CDN. `imageBase` is the catalog's
    /// `image_base` (e.g. "en/base/base1/4"); nil means TCGdex has no image
    /// for this card and the placeholder card back is returned immediately.
    func image(
        for cardID: String,
        imageBase: String?,
        quality: ImageQuality,
        pinned: Bool
    ) async throws -> CGImage {
        guard let imageBase, !imageBase.isEmpty else { return PlaceholderArt.cardBack }

        let key = Self.key(cardID: cardID, quality: quality)
        if let cached = memory.object(forKey: key as NSString) { return cached }

        if let image = loadFromDisk(cardID: cardID, quality: quality, promoteToPinned: pinned) {
            memory.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
            return image
        }

        if permanentNegatives.contains(key) { throw ImageCacheError.notFound }
        if let failedAt = transientNegatives[key] {
            if now().timeIntervalSince(failedAt) < Self.transientNegativeTTL {
                throw ImageCacheError.unavailable
            }
            transientNegatives[key] = nil
        }

        if let task = inFlight[key] { return try await task.value }

        guard let url = Self.remoteURL(imageBase: imageBase, quality: quality) else {
            permanentNegatives.insert(key)
            throw ImageCacheError.notFound
        }
        let task = Task {
            try await self.download(key: key, url: url, cardID: cardID, quality: quality, pinned: pinned)
        }
        inFlight[key] = task
        return try await task.value
    }

    /// Kicks off background fetches for a batch of cards (current + adjacent
    /// spreads). Fire-and-forget: failures are swallowed (and negative-cached).
    func prefetch(_ cards: [CardSummary], quality: ImageQuality, pinned: Bool) {
        for card in cards {
            Task {
                _ = try? await self.image(
                    for: card.id, imageBase: card.imageBase, quality: quality, pinned: pinned)
            }
        }
    }

    /// Moves any transient files for this card (all qualities) into the
    /// pinned store. Called when a card becomes owned or slotted.
    func pin(cardID: String) {
        let fileManager = FileManager.default
        for quality in ImageQuality.allCases {
            let transient = Self.fileURL(root: cachesRoot, quality: quality, cardID: cardID)
            guard fileManager.fileExists(atPath: transient.path) else { continue }
            let pinned = Self.fileURL(root: pinnedRoot, quality: quality, cardID: cardID)
            do {
                try fileManager.createDirectory(
                    at: pinned.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: pinned.path) {
                    try fileManager.removeItem(at: transient)
                } else {
                    try fileManager.moveItem(at: transient, to: pinned)
                }
            } catch {
                Self.logger.error("pin failed for \(cardID, privacy: .public): \(String(describing: error))")
            }
        }
    }

    // MARK: - Maintenance

    func diskUsage() -> (pinned: Int64, transient: Int64) {
        (Self.directorySize(pinnedRoot), Self.directorySize(cachesRoot))
    }

    /// Deletes the transient store (browse churn); pinned images survive.
    func clearTransient() {
        try? FileManager.default.removeItem(at: cachesRoot)
        try? FileManager.default.createDirectory(at: cachesRoot, withIntermediateDirectories: true)
        transientNegatives.removeAll()
    }

    /// Deletes everything: both disk stores, the memory cache, and all
    /// negative-cache state.
    func clearAll() {
        clearTransient()
        try? FileManager.default.removeItem(at: pinnedRoot)
        try? FileManager.default.createDirectory(at: pinnedRoot, withIntermediateDirectories: true)
        memory.removeAllObjects()
        permanentNegatives.removeAll()
    }

    // MARK: - Download

    private func download(
        key: String,
        url: URL,
        cardID: String,
        quality: ImageQuality,
        pinned: Bool
    ) async throws -> CGImage {
        defer { inFlight[key] = nil }
        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                if http.statusCode == 404 {
                    permanentNegatives.insert(key)
                    throw ImageCacheError.notFound
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                guard let image = Self.decode(data) else {
                    throw URLError(.cannotDecodeContentData)
                }
                write(data: data, cardID: cardID, quality: quality, pinned: pinned)
                memory.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
                return image
            } catch let error as ImageCacheError {
                throw error  // 404: permanent, never retried
            } catch {
                if attempt < retryDelays.count {
                    try? await Task.sleep(for: retryDelays[attempt])
                    attempt += 1
                    continue
                }
                transientNegatives[key] = now()
                Self.logger.warning("image download failed for \(key, privacy: .public): \(String(describing: error))")
                throw ImageCacheError.unavailable
            }
        }
    }

    // MARK: - Disk

    private func loadFromDisk(cardID: String, quality: ImageQuality, promoteToPinned: Bool) -> CGImage? {
        let fileManager = FileManager.default
        let pinnedURL = Self.fileURL(root: pinnedRoot, quality: quality, cardID: cardID)
        let transientURL = Self.fileURL(root: cachesRoot, quality: quality, cardID: cardID)

        var location: URL?
        if fileManager.fileExists(atPath: pinnedURL.path) {
            location = pinnedURL
        } else if fileManager.fileExists(atPath: transientURL.path) {
            if promoteToPinned {
                pin(cardID: cardID)
                location = fileManager.fileExists(atPath: pinnedURL.path) ? pinnedURL : transientURL
            } else {
                location = transientURL
            }
        }
        guard let location,
              let data = try? Data(contentsOf: location),
              let image = Self.decode(data)
        else { return nil }
        return image
    }

    private func write(data: Data, cardID: String, quality: ImageQuality, pinned: Bool) {
        let root = pinned ? pinnedRoot : cachesRoot
        let url = Self.fileURL(root: root, quality: quality, cardID: cardID)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            // Disk persistence is best-effort; the decoded image is still returned.
            Self.logger.error("image write failed for \(cardID, privacy: .public): \(String(describing: error))")
        }
    }

    private static func directorySize(_ root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    // MARK: - Pure helpers

    static func key(cardID: String, quality: ImageQuality) -> String {
        "\(cardID)|\(quality.rawValue)"
    }

    static func fileURL(root: URL, quality: ImageQuality, cardID: String) -> URL {
        root
            .appendingPathComponent(quality.rawValue, isDirectory: true)
            .appendingPathComponent("\(cardID).webp", isDirectory: false)
    }

    /// CDN URL for an image. `imageBase` is normally a relative base like
    /// "en/base/base1/4", but absolute URLs (older catalog builds) are
    /// tolerated.
    static func remoteURL(imageBase: String, quality: ImageQuality) -> URL? {
        let base = imageBase.lowercased().hasPrefix("http")
            ? imageBase
            : "https://assets.tcgdex.net/" + imageBase
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: "\(trimmed)/\(quality.rawValue).webp")
    }

    /// Image I/O decodes WebP natively on iOS 14+.
    static func decode(_ data: Data) -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }

    private static func cost(of image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }
}
