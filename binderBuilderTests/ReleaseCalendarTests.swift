//
//  ReleaseCalendarTests.swift
//  binderBuilderTests
//
//  Curated release calendar: Friday resolution across month/year/DST edges,
//  month-only entries, the bundled JSON, and the TCGdex promotion signal.
//

import Foundation
import Testing
@testable import binderBuilder

struct ReleaseCalendarTests {
    /// Fixed zone so DST transitions (2026-03-08 / 2026-11-01) are exercised.
    private let cal: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }()

    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
        cal.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
    }

    private func entry(
        id: String = "curated-x", name: String = "X", series: String = "S",
        date: String? = nil, month: String? = nil,
        confidence: String = "expected", source: String = "note", logo: String? = nil
    ) -> ReleaseFeed.Entry {
        ReleaseFeed.Entry(id: id, name: name, series: series, date: date, month: month,
                          confidence: confidence, source: source, logo: logo)
    }

    // MARK: nextFriday

    @Test func nextFridayReturnsTheSameDayWhenAlreadyFriday() {
        // 2026-11-06 is a Friday.
        #expect(ReleaseCalendar.nextFriday(onOrAfter: day(2026, 11, 6), calendar: cal) == day(2026, 11, 6))
    }

    @Test func nextFridayNormalizesToMidnight() {
        let midMorning = cal.date(bySettingHour: 11, minute: 30, second: 0, of: day(2026, 11, 6))!
        let friday = ReleaseCalendar.nextFriday(onOrAfter: midMorning, calendar: cal)
        #expect(friday == day(2026, 11, 6))
        #expect(cal.component(.hour, from: friday) == 0)
    }

    @Test func nextFridayCrossesAMonthBoundary() {
        // 2026-10-31 is a Saturday; the next Friday is in November.
        #expect(ReleaseCalendar.nextFriday(onOrAfter: day(2026, 10, 31), calendar: cal) == day(2026, 11, 6))
    }

    @Test func nextFridayCrossesAYearBoundary() {
        // 2026-12-28 is a Monday; 2027-01-01 is a Friday.
        #expect(ReleaseCalendar.nextFriday(onOrAfter: day(2026, 12, 28), calendar: cal) == day(2027, 1, 1))
    }

    @Test func nextFridaySurvivesDSTTransitions() {
        // Spring forward: 2026-03-08 (Sunday) -> Friday 2026-03-13.
        let spring = ReleaseCalendar.nextFriday(onOrAfter: day(2026, 3, 8), calendar: cal)
        #expect(spring == day(2026, 3, 13))
        #expect(cal.component(.hour, from: spring) == 0)
        // Fall back: 2026-11-01 (Sunday) -> Friday 2026-11-06.
        let fall = ReleaseCalendar.nextFriday(onOrAfter: day(2026, 11, 1), calendar: cal)
        #expect(fall == day(2026, 11, 6))
        #expect(cal.component(.hour, from: fall) == 0)
    }

    // MARK: Resolution

    @Test func monthOnlyEntriesResolveToTheFirstFridayAndStayExpected() throws {
        // 2026-12-01 is a Tuesday -> first Friday is the 4th.
        let december = try #require(ReleaseCalendar.resolve(entry(month: "2026-12", confidence: "confirmed"), calendar: cal))
        #expect(december.expectedDate == day(2026, 12, 4))
        #expect(december.isMonthEstimate)
        // We picked the day, so we never claim the publisher confirmed it.
        #expect(december.confidence == .expected)

        // 2027-01-01 is itself a Friday.
        let january = try #require(ReleaseCalendar.resolve(entry(month: "2027-01"), calendar: cal))
        #expect(january.expectedDate == day(2027, 1, 1))
    }

    @Test func exactDatesAreNotSnappedToFriday() throws {
        // 2026-09-16 is a Wednesday and must survive as-is.
        let release = try #require(ReleaseCalendar.resolve(entry(date: "2026-09-16", confidence: "confirmed"), calendar: cal))
        #expect(release.expectedDate == day(2026, 9, 16))
        #expect(!release.isMonthEstimate)
        #expect(release.confidence == .confirmed)
    }

    @Test func unparseableAndUnknownFieldsDegradeGracefully() {
        #expect(ReleaseCalendar.resolve(entry(), calendar: cal) == nil)
        #expect(ReleaseCalendar.resolve(entry(date: "not-a-date"), calendar: cal) == nil)
        #expect(ReleaseCalendar.resolve(entry(date: "2026-11-06", confidence: "wildly-unknown"),
                                        calendar: cal)?.confidence == .expected)
    }

    @Test func decodeSortsAscendingAndSkipsBadRows() throws {
        let json = """
        {"retrieved":"2026-07-28","releases":[
          {"id":"b","name":"B","series":"S","date":"2027-01-08","confidence":"expected","source":"n"},
          {"id":"broken","name":"Bad","series":"S","confidence":"expected","source":"n"},
          {"id":"a","name":"A","series":"S","date":"2026-11-06","confidence":"confirmed","source":"n"}
        ]}
        """
        let calendar = try ReleaseCalendar.decode(Data(json.utf8), calendar: cal)
        #expect(calendar.retrieved == "2026-07-28")
        #expect(calendar.releases.map(\.id) == ["a", "b"])
    }

    // MARK: Bundled feed

    @Test func bundledCalendarDecodes() throws {
        let calendar = ReleaseCalendar.load(bundle: .main, calendar: cal)
        #expect(!calendar.releases.isEmpty)
        #expect(!calendar.retrieved.isEmpty)
        // Sorted, uniquely identified, and every entry carries a sourced note.
        #expect(calendar.releases.map(\.expectedDate) == calendar.releases.map(\.expectedDate).sorted())
        #expect(Set(calendar.releases.map(\.id)).count == calendar.releases.count)
        #expect(calendar.releases.allSatisfy { !$0.sourceNote.isEmpty && !$0.name.isEmpty })
        // Month-only entries all landed on a Friday (weekday 6).
        for release in calendar.releases where release.isMonthEstimate {
            #expect(cal.component(.weekday, from: release.expectedDate) == 6)
            #expect(release.confidence == .expected)
        }
    }

    @Test func upcomingHonoursTheHorizon() {
        let now = day(2026, 8, 1)
        let releases = [10, 89, 120].map {
            UpcomingRelease(id: "r\($0)", name: "R", seriesName: "S",
                            expectedDate: cal.date(byAdding: .day, value: $0, to: now)!,
                            confidence: .expected, sourceNote: "n")
        }
        #expect(ReleaseCalendar.upcoming(releases, now: now).map(\.id) == ["r10", "r89"])
        #expect(ReleaseCalendar.upcoming(releases, now: now, within: 5 * 24 * 3600).isEmpty)
        // Past releases are not "upcoming".
        let past = UpcomingRelease(id: "old", name: "R", seriesName: "S",
                                   expectedDate: day(2026, 1, 1), confidence: .expected, sourceNote: "n")
        #expect(!ReleaseCalendar.upcoming(releases + [past], now: now).contains { $0.id == "old" })
    }

    // MARK: Promotion

    @Test func setTokensPullTCGdexShapedIDsOutOfCuratedIDs() {
        #expect(ReleaseCalendar.setTokens(in: "curated-me07-main-set") == ["me07"])
        #expect(ReleaseCalendar.setTokens(in: "curated-delta-reign").isEmpty)
        // "30th" starts with a digit, "q1" has a one-letter prefix, "2027" has none.
        #expect(ReleaseCalendar.setTokens(in: "curated-30th-celebration").isEmpty)
        #expect(ReleaseCalendar.setTokens(in: "curated-premium-collection-q1-2027").isEmpty)
    }

    @Test func promotedMatchesConfirmedSetsAndStaleGuesses() {
        let now = day(2026, 8, 1)
        let confirmedByTCGdex = UpcomingRelease(
            id: "curated-me07-main-set", name: "ME07", seriesName: "Mega Evolution",
            expectedDate: day(2026, 10, 2), confidence: .expected, sourceNote: "n")
        let stillPending = UpcomingRelease(
            id: "curated-delta-reign", name: "Delta Reign", seriesName: "Mega Evolution",
            expectedDate: day(2026, 11, 6), confidence: .expected, sourceNote: "n")
        let stale = UpcomingRelease(
            id: "curated-old-thing", name: "Old", seriesName: "S",
            expectedDate: day(2026, 7, 17), confidence: .expected, sourceNote: "n")
        let calendar = ReleaseCalendar(releases: [confirmedByTCGdex, stillPending, stale])

        let promoted = calendar.promoted(calendar: cal, remoteSetIDs: ["me05", "me06", "me07"], now: now)
        #expect(Set(promoted.map(\.id)) == ["curated-me07-main-set", "curated-old-thing"])

        // Without the confirming id, only the stale guess retires.
        let unconfirmed = calendar.promoted(calendar: cal, remoteSetIDs: ["me05", "me06"], now: now)
        #expect(unconfirmed.map(\.id) == ["curated-old-thing"])
        // A release due today is not yet stale.
        let today = calendar.promoted(calendar: cal, remoteSetIDs: [], now: day(2026, 7, 17))
        #expect(today.isEmpty)
    }
}
