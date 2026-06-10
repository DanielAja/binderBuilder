//
//  ImageCacheTests.swift
//  binderBuilderTests
//
//  ImageCache + PlaceholderArt tests, plus the shared network test rig
//  (MockURLProtocol) also used by PricingTests. No test ever hits the real
//  network: every URLSession is built over MockURLProtocol.
//
//  Parallel-safety: the URLProtocol route table is process-global, so every
//  test stubs URLs unique to itself (unique card ids / hosts / query terms)
//  and counts requests by prefix.
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import binderBuilder

// MARK: - Shared network test rig (used by PricingTests too)

nonisolated final class MockURLProtocol: URLProtocol {
    nonisolated struct Route {
        let urlPrefix: String
        let status: Int
        let body: Data
        let delay: TimeInterval
    }

    nonisolated struct LoggedRequest {
        let url: String
        let method: String
        let headers: [String: String]
    }

    /// Lock-guarded global route table + request log.
    nonisolated final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var routes: [Route] = []
        private var log: [LoggedRequest] = []

        func stub(urlPrefix: String, status: Int, body: Data, delay: TimeInterval = 0) {
            lock.lock(); defer { lock.unlock() }
            // Newest stub wins on overlapping prefixes.
            routes.insert(Route(urlPrefix: urlPrefix, status: status, body: body, delay: delay), at: 0)
        }

        func record(_ request: LoggedRequest) -> Route? {
            lock.lock(); defer { lock.unlock() }
            log.append(request)
            return routes.first { request.url.hasPrefix($0.urlPrefix) }
        }

        func requests(matching urlPrefix: String) -> [LoggedRequest] {
            lock.lock(); defer { lock.unlock() }
            return log.filter { $0.url.hasPrefix(urlPrefix) }
        }

        func requestCount(matching urlPrefix: String) -> Int {
            requests(matching: urlPrefix).count
        }
    }

    static let registry = Registry()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let logged = LoggedRequest(
            url: request.url?.absoluteString ?? "",
            method: request.httpMethod ?? "GET",
            headers: request.allHTTPHeaderFields ?? [:])
        guard let route = Self.registry.record(logged), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let client = self.client
        let respond: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(
                url: url, statusCode: route.status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: route.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if route.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + route.delay, execute: respond)
        } else {
            respond()
        }
    }
}

func makeMockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
}

/// Mutable test clock injectable as a `@Sendable () -> Date`.
nonisolated final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date = Date()) { self.date = date }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return date
    }

    func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        date = date.addingTimeInterval(interval)
    }
}

// MARK: - Fixtures

private final class FixtureLocator {}

func fixtureData(_ name: String, _ ext: String) throws -> Data {
    let bundle = Bundle(for: FixtureLocator.self)
    guard let url = bundle.url(forResource: name, withExtension: ext)
        ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
    else {
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "\(name).\(ext)"])
    }
    return try Data(contentsOf: url)
}

/// PNG payload generated at test time (iOS cannot encode WebP natively;
/// the real-WebP decode path is covered by the downloaded sample.webp).
func makeGradientPNG(width: Int = 64, height: Int = 88) -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for y in 0..<height {
        let shade = CGFloat(y) / CGFloat(height)
        context.setFillColor(CGColor(red: shade, green: 0.3, blue: 1 - shade, alpha: 1))
        context.fill(CGRect(x: 0, y: y, width: width, height: 1))
    }
    let image = context.makeImage()!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

func makeSummary(
    id: String = "base1-4",
    name: String = "Charizard",
    setID: String = "base1",
    setName: String = "Base Set",
    localNumber: String = "4",
    imageBase: String? = "en/base/base1/4"
) -> CardSummary {
    CardSummary(
        id: id, name: name, setID: setID, setName: setName, localNumber: localNumber,
        rarity: "Rare Holo", imageBase: imageBase, availableVariants: [.holo])
}

// MARK: - ImageCache test harness

private struct CacheHarness {
    let cache: ImageCache
    let clock: TestClock
    let pinnedRoot: URL
    let cachesRoot: URL

    init(retryDelays: [Duration] = [.milliseconds(1), .milliseconds(1)]) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageCacheTests-\(UUID().uuidString)", isDirectory: true)
        pinnedRoot = base.appendingPathComponent("pinned", isDirectory: true)
        cachesRoot = base.appendingPathComponent("transient", isDirectory: true)
        clock = TestClock()
        let clock = self.clock
        cache = ImageCache(
            session: makeMockSession(),
            pinnedRoot: pinnedRoot,
            cachesRoot: cachesRoot,
            retryDelays: retryDelays,
            now: { clock.now() })
    }

    /// A unique CDN imageBase so this test's stubs/counts can't collide
    /// with other tests running in parallel.
    static func uniqueImageBase(_ token: String) -> String {
        "en/test/\(token)"
    }
}

// MARK: - ImageCache tests

@Suite struct ImageCacheTests {
    @Test func nilImageBaseReturnsPlaceholderImmediately() async throws {
        let harness = CacheHarness()
        let image = try await harness.cache.image(
            for: "no-image-card", imageBase: nil, quality: .high, pinned: false)
        #expect(image === PlaceholderArt.cardBack)
        // Nothing was requested or written.
        let usage = await harness.cache.diskUsage()
        #expect(usage.pinned == 0)
        #expect(usage.transient == 0)
    }

    @Test func placeholderArtIsDeterministic() {
        let back = PlaceholderArt.cardBack
        #expect(back.width == 600)
        #expect(back.height == 825)
        // Rendered once, cached for the process lifetime.
        #expect(PlaceholderArt.cardBack === back)
        let loading = PlaceholderArt.loading
        #expect(loading.width == 600)
        #expect(loading.height == 825)
    }

    @Test func remoteURLBuilding() {
        #expect(
            ImageCache.remoteURL(imageBase: "en/base/base1/4", quality: .low)?.absoluteString
                == "https://assets.tcgdex.net/en/base/base1/4/low.webp")
        #expect(
            ImageCache.remoteURL(imageBase: "en/base/base1/4", quality: .high)?.absoluteString
                == "https://assets.tcgdex.net/en/base/base1/4/high.webp")
        // Older catalog builds stored absolute URLs; tolerated.
        #expect(
            ImageCache.remoteURL(imageBase: "https://assets.tcgdex.net/en/base/base1/4", quality: .low)?
                .absoluteString == "https://assets.tcgdex.net/en/base/base1/4/low.webp")
    }

    @Test func concurrentRequestsAreDeduplicated() async throws {
        let token = "dedup-\(UUID().uuidString)"
        let imageBase = CacheHarness.uniqueImageBase(token)
        let urlPrefix = "https://assets.tcgdex.net/\(imageBase)/"
        MockURLProtocol.registry.stub(
            urlPrefix: urlPrefix, status: 200, body: makeGradientPNG(), delay: 0.1)

        let harness = CacheHarness()
        async let first = harness.cache.image(
            for: token, imageBase: imageBase, quality: .low, pinned: false)
        async let second = harness.cache.image(
            for: token, imageBase: imageBase, quality: .low, pinned: false)
        let images = try await (first, second)

        #expect(images.0.width == 64)
        #expect(images.1.width == 64)
        #expect(MockURLProtocol.registry.requestCount(matching: urlPrefix) == 1)
    }

    @Test func realWebPFixtureDecodesToExpectedPixelSize() async throws {
        let webp = try fixtureData("sample", "webp")
        let token = "webp-\(UUID().uuidString)"
        let imageBase = CacheHarness.uniqueImageBase(token)
        MockURLProtocol.registry.stub(
            urlPrefix: "https://assets.tcgdex.net/\(imageBase)/", status: 200, body: webp)

        let harness = CacheHarness()
        let image = try await harness.cache.image(
            for: token, imageBase: imageBase, quality: .low, pinned: false)
        // assets.tcgdex.net low.webp is 245x337.
        #expect(image.width == 245)
        #expect(image.height == 337)

        // Round-trip: the bytes on disk decode too.
        let onDisk = ImageCache.fileURL(root: harness.cachesRoot, quality: .low, cardID: token)
        let decoded = ImageCache.decode(try Data(contentsOf: onDisk))
        #expect(decoded?.width == 245)
    }

    @Test func transientFailuresRetryThenNegativeCacheFiveMinutes() async throws {
        let token = "transient-\(UUID().uuidString)"
        let imageBase = CacheHarness.uniqueImageBase(token)
        let urlPrefix = "https://assets.tcgdex.net/\(imageBase)/"
        MockURLProtocol.registry.stub(urlPrefix: urlPrefix, status: 500, body: Data())

        let harness = CacheHarness()
        await #expect(throws: ImageCacheError.unavailable) {
            _ = try await harness.cache.image(
                for: token, imageBase: imageBase, quality: .low, pinned: false)
        }
        // Initial attempt + 2 retries.
        #expect(MockURLProtocol.registry.requestCount(matching: urlPrefix) == 3)

        // Within the 5-minute negative-cache window: fails fast, no network.
        await #expect(throws: ImageCacheError.unavailable) {
            _ = try await harness.cache.image(
                for: token, imageBase: imageBase, quality: .low, pinned: false)
        }
        #expect(MockURLProtocol.registry.requestCount(matching: urlPrefix) == 3)

        // After expiry the cache tries the network again.
        harness.clock.advance(by: 6 * 60)
        await #expect(throws: ImageCacheError.unavailable) {
            _ = try await harness.cache.image(
                for: token, imageBase: imageBase, quality: .low, pinned: false)
        }
        #expect(MockURLProtocol.registry.requestCount(matching: urlPrefix) == 6)
    }

    @Test func notFoundIsPermanentAndNeverRetried() async throws {
        let token = "missing-\(UUID().uuidString)"
        let imageBase = CacheHarness.uniqueImageBase(token)
        let urlPrefix = "https://assets.tcgdex.net/\(imageBase)/"
        MockURLProtocol.registry.stub(urlPrefix: urlPrefix, status: 404, body: Data())

        let harness = CacheHarness()
        await #expect(throws: ImageCacheError.notFound) {
            _ = try await harness.cache.image(
                for: token, imageBase: imageBase, quality: .low, pinned: false)
        }
        // 404 is not retried.
        #expect(MockURLProtocol.registry.requestCount(matching: urlPrefix) == 1)

        // Permanent: even after the transient window would have expired.
        harness.clock.advance(by: 60 * 60)
        await #expect(throws: ImageCacheError.notFound) {
            _ = try await harness.cache.image(
                for: token, imageBase: imageBase, quality: .low, pinned: false)
        }
        #expect(MockURLProtocol.registry.requestCount(matching: urlPrefix) == 1)
    }

    @Test func pinMovesTransientFileToPinnedStore() async throws {
        let token = "pinme-\(UUID().uuidString)"
        let imageBase = CacheHarness.uniqueImageBase(token)
        MockURLProtocol.registry.stub(
            urlPrefix: "https://assets.tcgdex.net/\(imageBase)/", status: 200,
            body: makeGradientPNG())

        let harness = CacheHarness()
        _ = try await harness.cache.image(
            for: token, imageBase: imageBase, quality: .low, pinned: false)

        let transientURL = ImageCache.fileURL(root: harness.cachesRoot, quality: .low, cardID: token)
        let pinnedURL = ImageCache.fileURL(root: harness.pinnedRoot, quality: .low, cardID: token)
        #expect(FileManager.default.fileExists(atPath: transientURL.path))
        #expect(!FileManager.default.fileExists(atPath: pinnedURL.path))

        await harness.cache.pin(cardID: token)

        #expect(!FileManager.default.fileExists(atPath: transientURL.path))
        #expect(FileManager.default.fileExists(atPath: pinnedURL.path))
    }

    @Test func pinnedFetchWritesToPinnedStore() async throws {
        let token = "pinned-\(UUID().uuidString)"
        let imageBase = CacheHarness.uniqueImageBase(token)
        MockURLProtocol.registry.stub(
            urlPrefix: "https://assets.tcgdex.net/\(imageBase)/", status: 200,
            body: makeGradientPNG())

        let harness = CacheHarness()
        _ = try await harness.cache.image(
            for: token, imageBase: imageBase, quality: .high, pinned: true)

        let pinnedURL = ImageCache.fileURL(root: harness.pinnedRoot, quality: .high, cardID: token)
        #expect(FileManager.default.fileExists(atPath: pinnedURL.path))
        let transientURL = ImageCache.fileURL(root: harness.cachesRoot, quality: .high, cardID: token)
        #expect(!FileManager.default.fileExists(atPath: transientURL.path))
    }

    @Test func diskUsageAndClearing() async throws {
        let payload = makeGradientPNG()
        let pinnedToken = "usage-p-\(UUID().uuidString)"
        let transientToken = "usage-t-\(UUID().uuidString)"
        for token in [pinnedToken, transientToken] {
            MockURLProtocol.registry.stub(
                urlPrefix: "https://assets.tcgdex.net/\(CacheHarness.uniqueImageBase(token))/",
                status: 200, body: payload)
        }

        let harness = CacheHarness()
        _ = try await harness.cache.image(
            for: pinnedToken, imageBase: CacheHarness.uniqueImageBase(pinnedToken),
            quality: .low, pinned: true)
        _ = try await harness.cache.image(
            for: transientToken, imageBase: CacheHarness.uniqueImageBase(transientToken),
            quality: .low, pinned: false)

        let usage = await harness.cache.diskUsage()
        #expect(usage.pinned == Int64(payload.count))
        #expect(usage.transient == Int64(payload.count))

        await harness.cache.clearTransient()
        let afterTransientClear = await harness.cache.diskUsage()
        #expect(afterTransientClear.pinned == Int64(payload.count))
        #expect(afterTransientClear.transient == 0)

        await harness.cache.clearAll()
        let afterClearAll = await harness.cache.diskUsage()
        #expect(afterClearAll.pinned == 0)
        #expect(afterClearAll.transient == 0)
    }

    @Test func diskHitServesWithoutNetwork() async throws {
        let token = "diskhit-\(UUID().uuidString)"
        let imageBase = CacheHarness.uniqueImageBase(token)
        let urlPrefix = "https://assets.tcgdex.net/\(imageBase)/"
        MockURLProtocol.registry.stub(urlPrefix: urlPrefix, status: 200, body: makeGradientPNG())

        let first = CacheHarness()
        _ = try await first.cache.image(
            for: token, imageBase: imageBase, quality: .low, pinned: false)
        #expect(MockURLProtocol.registry.requestCount(matching: urlPrefix) == 1)

        // A fresh cache instance over the same roots (cold memory cache)
        // must serve from disk, not the network.
        let second = ImageCache(
            session: makeMockSession(),
            pinnedRoot: first.pinnedRoot,
            cachesRoot: first.cachesRoot,
            retryDelays: [])
        let image = try await second.image(
            for: token, imageBase: imageBase, quality: .low, pinned: false)
        #expect(image.width == 64)
        #expect(MockURLProtocol.registry.requestCount(matching: urlPrefix) == 1)
    }

    @Test func prefetchPopulatesDisk() async throws {
        let token = "prefetch-\(UUID().uuidString)"
        let imageBase = CacheHarness.uniqueImageBase(token)
        MockURLProtocol.registry.stub(
            urlPrefix: "https://assets.tcgdex.net/\(imageBase)/", status: 200,
            body: makeGradientPNG())

        let harness = CacheHarness()
        let card = makeSummary(id: token, imageBase: imageBase)
        await harness.cache.prefetch([card], quality: .low, pinned: false)

        // Fire-and-forget: poll briefly for the file to land.
        let fileURL = ImageCache.fileURL(root: harness.cachesRoot, quality: .low, cardID: token)
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: fileURL.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }
}
