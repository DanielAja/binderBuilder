//
//  TCGdexPriceProvider.swift
//  binderBuilder
//
//  Live prices from the free TCGdex API (no key). One GET per card:
//  https://api.tcgdex.net/v2/en/cards/{id} — only the `pricing` subtree is
//  parsed, tolerantly: absent/null/garbage pricing yields no quotes, never
//  an error, as long as the HTTP response itself is sound.
//
//  Observed response shape (fixture binderBuilderTests/Fixtures/tcgdex_card.json):
//    pricing.cardmarket: flat EUR object — unit, trend, avg, avg1/7/30, low,
//                        plus "-holo"-suffixed twins (ignored; quotes map to
//                        the `normal` variant per the cross-layer contract).
//    pricing.tcgplayer:  unit ("USD") + variant-keyed objects ("normal",
//                        "holofoil", "reverse-holofoil", "1st-edition") each
//                        carrying lowPrice/midPrice/highPrice/marketPrice.
//

import Foundation

nonisolated struct TCGdexPriceProvider: PriceProvider {
    let id = "tcgdex"

    private let session: URLSession
    private let now: @Sendable () -> Date

    init(session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.now = now
    }

    func quotes(for card: CardSummary) async throws -> [PriceQuote] {
        let escapedID = card.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? card.id
        guard let url = URL(string: "https://api.tcgdex.net/v2/en/cards/\(escapedID)") else {
            throw PricingError.malformedResponse
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw PricingError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else { throw PricingError.badStatus(http.statusCode) }
        return Self.parseQuotes(from: data, fetchedAt: now())
    }

    // MARK: - Parsing (internal for tests)

    /// TCGdex tcgplayer variant key -> our variant. Unknown keys are skipped.
    static let tcgplayerVariantMap: [String: CardVariant] = [
        "normal": .normal,
        "holofoil": .holo,
        "reverse-holofoil": .reverse,
        "1st-edition": .firstEdition,
    ]

    static func parseQuotes(from data: Data, fetchedAt: Date) -> [PriceQuote] {
        guard let envelope = try? JSONDecoder().decode(CardEnvelope.self, from: data),
              let pricing = envelope.pricing
        else { return [] }

        var quotes: [PriceQuote] = []

        if let tcgplayer = pricing.tcgplayer {
            for (key, variant) in tcgplayerVariantMap {
                guard let price = tcgplayer.variantPrices[key],
                      price.marketPrice != nil || price.lowPrice != nil
                else { continue }
                quotes.append(PriceQuote(
                    source: .tcgplayer,
                    variant: variant,
                    currency: tcgplayer.unit ?? "USD",
                    market: price.marketPrice,
                    low: price.lowPrice,
                    fetchedAt: fetchedAt,
                    isLive: true))
            }
        }

        if let cardmarket = pricing.cardmarket {
            let market = cardmarket.trend ?? cardmarket.avg30 ?? cardmarket.avg
            if market != nil || cardmarket.low != nil {
                quotes.append(PriceQuote(
                    source: .cardmarket,
                    variant: .normal,
                    currency: cardmarket.unit ?? "EUR",
                    market: market,
                    low: cardmarket.low,
                    fetchedAt: fetchedAt,
                    isLive: true))
            }
        }

        // Dictionary iteration order is random; keep output deterministic.
        return quotes.sorted {
            ($0.source.rawValue, $0.variant.rawValue) < ($1.source.rawValue, $1.variant.rawValue)
        }
    }

    // MARK: - Tolerant Decodable shims

    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(_ string: String) { self.stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private static func lenientDouble(_ container: KeyedDecodingContainer<AnyKey>, _ key: String) -> Double? {
        let codingKey = AnyKey(key)
        if let value = (try? container.decodeIfPresent(Double.self, forKey: codingKey)) ?? nil {
            return value
        }
        if let text = (try? container.decodeIfPresent(String.self, forKey: codingKey)) ?? nil {
            return Double(text)
        }
        return nil
    }

    private static func lenientString(_ container: KeyedDecodingContainer<AnyKey>, _ key: String) -> String? {
        (try? container.decodeIfPresent(String.self, forKey: AnyKey(key))) ?? nil
    }

    private struct CardEnvelope: Decodable {
        let pricing: PricingNode?
        init(from decoder: Decoder) throws {
            let container = try? decoder.container(keyedBy: AnyKey.self)
            pricing = container.flatMap {
                (try? $0.decodeIfPresent(PricingNode.self, forKey: AnyKey("pricing"))) ?? nil
            }
        }
    }

    private struct PricingNode: Decodable {
        let cardmarket: CardmarketNode?
        let tcgplayer: TCGPlayerNode?
        init(from decoder: Decoder) throws {
            let container = try? decoder.container(keyedBy: AnyKey.self)
            cardmarket = container.flatMap {
                (try? $0.decodeIfPresent(CardmarketNode.self, forKey: AnyKey("cardmarket"))) ?? nil
            }
            tcgplayer = container.flatMap {
                (try? $0.decodeIfPresent(TCGPlayerNode.self, forKey: AnyKey("tcgplayer"))) ?? nil
            }
        }
    }

    private struct CardmarketNode: Decodable {
        let unit: String?
        let trend: Double?
        let avg30: Double?
        let avg: Double?
        let low: Double?
        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: AnyKey.self) else {
                unit = nil; trend = nil; avg30 = nil; avg = nil; low = nil
                return
            }
            unit = lenientString(container, "unit")
            trend = lenientDouble(container, "trend")
            avg30 = lenientDouble(container, "avg30")
            avg = lenientDouble(container, "avg")
            low = lenientDouble(container, "low")
        }
    }

    fileprivate struct TCGPlayerNode: Decodable {
        struct VariantPrice {
            let marketPrice: Double?
            let lowPrice: Double?
        }

        let unit: String?
        /// Raw TCGdex variant key ("holofoil", ...) -> prices.
        let variantPrices: [String: VariantPrice]

        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: AnyKey.self) else {
                unit = nil
                variantPrices = [:]
                return
            }
            unit = lenientString(container, "unit")
            var prices: [String: VariantPrice] = [:]
            for key in container.allKeys where key.stringValue != "unit" && key.stringValue != "updated" {
                guard let nested = try? container.nestedContainer(keyedBy: AnyKey.self, forKey: key) else {
                    continue
                }
                let market = lenientDouble(nested, "marketPrice")
                let low = lenientDouble(nested, "lowPrice")
                if market != nil || low != nil {
                    prices[key.stringValue] = VariantPrice(marketPrice: market, lowPrice: low)
                }
            }
            variantPrices = prices
        }
    }
}
