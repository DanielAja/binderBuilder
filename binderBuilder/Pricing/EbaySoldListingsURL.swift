//
//  EbaySoldListingsURL.swift
//  binderBuilder
//
//  Zero-API "View sold on eBay" link-out: a sold+completed listings search
//  URL opened in SFSafariViewController. No eBay credentials involved.
//

import Foundation

nonisolated enum EbaySoldListingsURL {
    /// e.g. https://www.ebay.com/sch/i.html?_nkw=pokemon+card+Farfetch%27d+Base+Set+27&LH_Sold=1&LH_Complete=1
    static func url(for card: CardSummary) -> URL {
        let words = "pokemon card \(card.name) \(card.setName) \(card.localNumber)"
            .split(whereSeparator: \.isWhitespace)
            .map { encodeTerm(String($0)) }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.ebay.com"
        components.path = "/sch/i.html"
        components.percentEncodedQuery =
            "_nkw=\(words.joined(separator: "+"))&LH_Sold=1&LH_Complete=1"
        // The query is fully percent-encoded above, so this cannot fail;
        // fall back to the bare search page out of an abundance of caution.
        return components.url ?? URL(string: "https://www.ebay.com/sch/i.html")!
    }

    /// RFC 3986 unreserved characters — everything else (apostrophes,
    /// accents, ampersands...) gets percent-encoded.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encodeTerm(_ term: String) -> String {
        term.addingPercentEncoding(withAllowedCharacters: unreserved) ?? term
    }
}
