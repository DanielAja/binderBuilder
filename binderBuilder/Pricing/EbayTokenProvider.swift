//
//  EbayTokenProvider.swift
//  binderBuilder
//
//  OAuth2 client-credentials flow against the eBay identity endpoint, using
//  the developer credentials the user pasted into Settings. The application
//  token is cached until 5 minutes before its expiry.
//

import Foundation

/// Seam so EbayBrowseProvider can be tested with a canned token.
nonisolated protocol EbayTokenProviding: Sendable {
    func token() async throws -> String
}

actor EbayTokenProvider: EbayTokenProviding {
    static let endpoint = URL(string: "https://api.ebay.com/identity/v1/oauth2/token")!
    /// Refresh this long before the reported expiry.
    static let expiryMargin: TimeInterval = 5 * 60

    private let appID: String
    private let certID: String
    private let session: URLSession
    private let now: @Sendable () -> Date

    private var cached: (token: String, expiry: Date)?

    init(
        appID: String,
        certID: String,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.appID = appID
        self.certID = certID
        self.session = session
        self.now = now
    }

    func token() async throws -> String {
        if let cached, now() < cached.expiry { return cached.token }
        guard !appID.isEmpty, !certID.isEmpty else { throw PricingError.notConfigured }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        let credentials = Data("\(appID):\(certID)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            "grant_type=client_credentials&scope=https%3A%2F%2Fapi.ebay.com%2Foauth%2Fapi_scope".utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PricingError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else { throw PricingError.badStatus(http.statusCode) }

        struct TokenResponse: Decodable {
            let accessToken: String
            let expiresIn: Double?
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case expiresIn = "expires_in"
            }
        }
        guard let payload = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw PricingError.malformedResponse
        }
        let lifetime = payload.expiresIn ?? 7200
        cached = (payload.accessToken, now().addingTimeInterval(lifetime - Self.expiryMargin))
        return payload.accessToken
    }
}
