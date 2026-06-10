//
//  EbayBrowseProvider.swift
//  binderBuilder
//
//  Optional live price source: median asking price of active eBay listings
//  via the Browse API (item_summary/search, category 183454 = CCG Individual
//  Cards). Engaged only when the user enabled eBay pricing and pasted their
//  own developer credentials. Budgeted by DailyRateLimiter.
//

import Foundation

nonisolated struct EbayBrowseProvider: PriceProvider {
    let id = "ebay"

    static let endpoint = "https://api.ebay.com/buy/browse/v1/item_summary/search"

    private let session: URLSession
    private let tokenProvider: any EbayTokenProviding
    private let limiter: DailyRateLimiter
    private let now: @Sendable () -> Date

    init(
        session: URLSession = .shared,
        tokenProvider: any EbayTokenProviding,
        limiter: DailyRateLimiter,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.tokenProvider = tokenProvider
        self.limiter = limiter
        self.now = now
    }

    func quotes(for card: CardSummary) async throws -> [PriceQuote] {
        guard await limiter.consume() else { throw PricingError.rateLimited }
        let token = try await tokenProvider.token()

        guard var components = URLComponents(string: Self.endpoint) else {
            throw PricingError.malformedResponse
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: "pokemon \(card.name) \(card.setName) \(card.localNumber)"),
            URLQueryItem(name: "category_ids", value: "183454"),
            URLQueryItem(name: "limit", value: "50"),
        ]
        guard let url = components.url else { throw PricingError.malformedResponse }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("EBAY_US", forHTTPHeaderField: "X-EBAY-C-MARKETPLACE-ID")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PricingError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else { throw PricingError.badStatus(http.statusCode) }

        let prices = Self.usdPrices(from: data)
        guard let median = Self.median(of: prices) else { return [] }
        // Active listings are not variant-aware; quotes land on the `normal`
        // variant by the same card-level convention Cardmarket uses.
        return [PriceQuote(
            source: .ebayActive,
            variant: .normal,
            currency: "USD",
            market: median,
            low: prices.min(),
            fetchedAt: now(),
            isLive: true)]
    }

    // MARK: - Parsing (internal for tests)

    /// All USD prices in the response's itemSummaries, tolerant of missing
    /// or malformed entries. `price.value` arrives as a string ("12.50").
    static func usdPrices(from data: Data) -> [Double] {
        struct SearchResponse: Decodable {
            struct Item: Decodable {
                struct Price: Decodable {
                    let value: LenientDouble?
                    let currency: String?
                }
                let price: Price?
            }
            let itemSummaries: [Item]?
        }
        guard let response = try? JSONDecoder().decode(SearchResponse.self, from: data) else { return [] }
        return (response.itemSummaries ?? []).compactMap { item in
            guard let price = item.price,
                  price.currency == nil || price.currency == "USD"
            else { return nil }
            return price.value?.value
        }
    }

    /// Standard median: middle element (odd count) or mean of the two middle
    /// elements (even count); nil for an empty list.
    static func median(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    /// Decodes a number that may arrive as a JSON string or number.
    struct LenientDouble: Decodable {
        let value: Double
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                value = number
            } else if let text = try? container.decode(String.self), let number = Double(text) {
                value = number
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "not a number")
            }
        }
    }
}
