//
//  UpcomingRelease.swift
//  binderBuilder
//
//  An upcoming set/product from the curated release calendar bundled with the
//  app (Resources/upcoming_releases.json). Purely a value type: the decoding
//  DTOs live here too, but the month -> date resolution is ReleaseCalendar's.
//

import Foundation

/// How firm a release date is. Curated entries are `.expected` until the
/// TCGdex set index confirms them (see `ReleaseCalendar.promoted`).
nonisolated enum ReleaseConfidence: String, Codable, Sendable, CaseIterable {
    case confirmed
    case expected
    case rumored
}

/// One upcoming release, with its date already resolved to a concrete day.
///
/// `expectedDate` is midnight (local) on the release day. Entries that only
/// gave a month resolve to the first Friday on/after the 1st and are always
/// `.expected` with `isMonthEstimate == true`.
nonisolated struct UpcomingRelease: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var seriesName: String
    var expectedDate: Date
    var confidence: ReleaseConfidence
    var sourceNote: String
    var logoURL: URL?
    /// True when the feed only gave a month and we picked a Friday for it.
    var isMonthEstimate: Bool

    init(
        id: String,
        name: String,
        seriesName: String,
        expectedDate: Date,
        confidence: ReleaseConfidence,
        sourceNote: String,
        logoURL: URL? = nil,
        isMonthEstimate: Bool = false
    ) {
        self.id = id
        self.name = name
        self.seriesName = seriesName
        self.expectedDate = expectedDate
        self.confidence = confidence
        self.sourceNote = sourceNote
        self.logoURL = logoURL
        self.isMonthEstimate = isMonthEstimate
    }
}

// MARK: - Feed DTOs

/// The on-disk shape of Resources/upcoming_releases.json.
nonisolated struct ReleaseFeed: Decodable, Sendable {
    /// The day the curation was last refreshed, as written in the file.
    var retrieved: String
    var releases: [Entry]

    nonisolated struct Entry: Decodable, Sendable {
        var id: String
        var name: String
        var series: String
        /// Exact day, `yyyy-MM-dd`. Mutually exclusive with `month`.
        var date: String?
        /// Month-only estimate, `yyyy-MM`.
        var month: String?
        var confidence: String
        var source: String
        var logo: String?
    }
}
