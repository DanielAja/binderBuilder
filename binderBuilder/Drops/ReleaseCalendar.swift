//
//  ReleaseCalendar.swift
//  binderBuilder
//
//  Loads the curated upcoming-release calendar bundled with the app and answers
//  the two questions the drop reminders need: what is coming up inside the
//  horizon, and which curated entries TCGdex has since confirmed. All pure and
//  calendar-injectable so the date math is unit-testable across DST/year edges.
//

import Foundation
import OSLog

nonisolated struct ReleaseCalendar: Sendable {
    private static let logger = Logger(subsystem: "com.aja.binderBuilder", category: "ReleaseCalendar")

    /// How far ahead we schedule reminders (matches the scheduler's horizon).
    static let defaultHorizon: TimeInterval = 90 * 24 * 60 * 60

    /// The `retrieved` stamp from the feed, verbatim (`yyyy-MM-dd`).
    let retrieved: String
    /// Releases with dates resolved, ascending by `expectedDate`.
    let releases: [UpcomingRelease]

    init(retrieved: String = "", releases: [UpcomingRelease] = []) {
        self.retrieved = retrieved
        self.releases = releases.sorted { ($0.expectedDate, $0.id) < ($1.expectedDate, $1.id) }
    }

    // MARK: - Loading

    /// The calendar shipped in the app bundle, or an empty calendar when the
    /// resource is missing/corrupt (drops simply go quiet, nothing crashes).
    static func load(bundle: Bundle = .main, calendar: Calendar = .current) -> ReleaseCalendar {
        guard let url = bundle.url(forResource: "upcoming_releases", withExtension: "json") else {
            logger.warning("upcoming_releases.json not found in bundle; no drop reminders")
            return ReleaseCalendar()
        }
        do {
            return try decode(Data(contentsOf: url), calendar: calendar)
        } catch {
            logger.error("failed to load upcoming_releases.json: \(String(describing: error), privacy: .public)")
            return ReleaseCalendar()
        }
    }

    /// Decodes the feed and resolves every entry's date. Entries whose date is
    /// unparseable are dropped rather than failing the whole calendar.
    static func decode(_ data: Data, calendar: Calendar = .current) throws -> ReleaseCalendar {
        let feed = try JSONDecoder().decode(ReleaseFeed.self, from: data)
        let releases = feed.releases.compactMap { resolve($0, calendar: calendar) }
        if releases.count != feed.releases.count {
            logger.warning("dropped \(feed.releases.count - releases.count, privacy: .public) release entries with unparseable dates")
        }
        return ReleaseCalendar(retrieved: feed.retrieved, releases: releases)
    }

    /// Turns a feed entry into a dated release. A `date` is taken as-is; a
    /// month-only entry resolves to the first Friday on/after the 1st and is
    /// forced to `.expected` (we picked the day, the publisher didn't).
    static func resolve(_ entry: ReleaseFeed.Entry, calendar: Calendar) -> UpcomingRelease? {
        let stated = ReleaseConfidence(rawValue: entry.confidence) ?? .expected
        let date: Date
        let isMonthEstimate: Bool
        if let day = entry.date, let parsed = self.date(fromDay: day, calendar: calendar) {
            date = parsed
            isMonthEstimate = false
        } else if let month = entry.month, let first = self.date(fromMonth: month, calendar: calendar) {
            date = nextFriday(onOrAfter: first, calendar: calendar)
            isMonthEstimate = true
        } else {
            return nil
        }
        return UpcomingRelease(
            id: entry.id,
            name: entry.name,
            seriesName: entry.series,
            expectedDate: date,
            confidence: isMonthEstimate ? .expected : stated,
            sourceNote: entry.source,
            logoURL: entry.logo.flatMap(URL.init(string:)),
            isMonthEstimate: isMonthEstimate)
    }

    // MARK: - Date math

    /// The first Friday on or after `date`, at midnight in `calendar`'s zone.
    /// Returns `date`'s own day when it already is a Friday.
    static func nextFriday(onOrAfter date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: start)
        // Gregorian weekday: 1 = Sunday ... 6 = Friday.
        let delta = (6 - weekday + 7) % 7
        guard delta > 0 else { return start }
        // Add whole days (not seconds) so DST transitions keep us at midnight.
        return calendar.date(byAdding: .day, value: delta, to: start) ?? start
    }

    /// Parses `yyyy-MM-dd` as midnight in `calendar`'s zone.
    static func date(fromDay text: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    /// Parses `yyyy-MM` as midnight on the 1st in `calendar`'s zone.
    static func date(fromMonth text: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]) else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: 1))
    }

    // MARK: - Queries

    /// Releases due in `[now, now + horizon]`, ascending.
    static func upcoming(
        _ releases: [UpcomingRelease],
        now: Date,
        within horizon: TimeInterval = defaultHorizon
    ) -> [UpcomingRelease] {
        let cutoff = now.addingTimeInterval(horizon)
        return releases
            .filter { $0.expectedDate >= now && $0.expectedDate <= cutoff }
            .sorted { ($0.expectedDate, $0.id) < ($1.expectedDate, $1.id) }
    }

    /// Convenience over this calendar's own releases.
    func upcoming(now: Date, within horizon: TimeInterval = defaultHorizon) -> [UpcomingRelease] {
        Self.upcoming(releases, now: now, within: horizon)
    }

    /// Curated entries TCGdex has confirmed — i.e. the ones we should stop
    /// reminding about. Two signals:
    ///
    /// 1. the curated id embeds a projected TCGdex set token (e.g.
    ///    `curated-me07-main-set` -> `me07`) that now exists in the live index;
    /// 2. the expected day is already behind us (by calendar day), so the
    ///    guess either landed or was wrong — either way it is stale.
    func promoted(
        calendar: Calendar = .current,
        remoteSetIDs: Set<String>,
        now: Date = Date()
    ) -> [UpcomingRelease] {
        let today = calendar.startOfDay(for: now)
        return releases.filter { release in
            if calendar.startOfDay(for: release.expectedDate) < today { return true }
            return !Self.setTokens(in: release.id).isDisjoint(with: remoteSetIDs)
        }
    }

    /// The TCGdex-shaped set ids embedded in a curated release id: hyphen
    /// components like `me07` / `sv10` / `base1` (letters then digits).
    static func setTokens(in releaseID: String) -> Set<String> {
        Set(releaseID.split(separator: "-").map(String.init).filter { token in
            let letters = token.prefix(while: { $0.isLetter })
            let digits = token.dropFirst(letters.count)
            return (2...4).contains(letters.count)
                && (1...3).contains(digits.count)
                && digits.allSatisfy(\.isNumber)
        })
    }
}
