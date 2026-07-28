//
//  DropScheduleTests.swift
//  binderBuilderTests
//
//  The pure reminder plan: beat times, past/horizon filtering, subscription
//  deviations, the 48-request cap, copy, and idempotence.
//

import Foundation
import Testing
@testable import binderBuilder

struct DropScheduleTests {
    private let cal: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }()

    /// 2026-08-01, noon — every fixture is relative to this.
    private var now: Date { cal.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 12))! }

    private func release(
        _ id: String, inDays days: Int, name: String = "Delta Reign",
        confidence: ReleaseConfidence = .expected
    ) -> UpcomingRelease {
        let day = cal.date(byAdding: .day, value: days, to: cal.startOfDay(for: now))!
        return UpcomingRelease(id: id, name: name, seriesName: "Mega Evolution",
                               expectedDate: day, confidence: confidence, sourceNote: "n")
    }

    private func plan(
        _ releases: [UpcomingRelease],
        subscriptions: [String: Bool] = [:],
        favoriteCount: Int = 0
    ) -> [DropNotificationPlan] {
        DropScheduler.plan(releases: releases, subscriptions: subscriptions,
                           now: now, favoriteCount: favoriteCount, calendar: cal)
    }

    // MARK: Beats

    @Test func eachReleaseGetsThreeBeatsAtTheContractedTimes() throws {
        let plans = plan([release("a", inDays: 30)])
        #expect(plans.map(\.beat) == [.t7, .t1, .day])
        #expect(plans.map(\.id) == ["drop-a-t7", "drop-a-t1", "drop-a-day"])
        #expect(plans.allSatisfy { $0.id.hasPrefix(DropScheduler.identifierPrefix) })
        #expect(plans.allSatisfy { $0.releaseID == "a" })

        let releaseDay = cal.startOfDay(for: try #require(plans.first).fireDate.addingTimeInterval(7 * 86_400))
        for item in plans {
            let components = item.dateComponents
            #expect(components.minute == 0)
            // Components must round-trip to the fire instant in the local zone.
            #expect(cal.date(from: components) == item.fireDate)
        }
        #expect(cal.component(.hour, from: plans[0].fireDate) == 10)
        #expect(cal.component(.hour, from: plans[1].fireDate) == 18)
        #expect(cal.component(.hour, from: plans[2].fireDate) == 9)
        #expect(cal.startOfDay(for: plans[2].fireDate) == releaseDay)
        // t7 is a full week before the release day, t1 the day before.
        let days = { (from: Date, to: Date) in
            self.cal.dateComponents([.day], from: self.cal.startOfDay(for: from),
                                    to: self.cal.startOfDay(for: to)).day
        }
        #expect(days(plans[0].fireDate, plans[2].fireDate) == 7)
        #expect(days(plans[1].fireDate, plans[2].fireDate) == 1)
    }

    @Test func beatsSurviveADSTTransition() throws {
        // Release 2026-11-06; the t7 beat sits on 2026-10-30, the other side of
        // the 2026-11-01 fall-back.
        let day = cal.date(from: DateComponents(year: 2026, month: 11, day: 6))!
        let release = UpcomingRelease(id: "dst", name: "R", seriesName: "S",
                                      expectedDate: day, confidence: .expected, sourceNote: "n")
        let october = cal.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12))!
        let plans = DropScheduler.plan(releases: [release], subscriptions: [:], now: october,
                                       favoriteCount: 0, calendar: cal)
        let t7 = try #require(plans.first { $0.beat == .t7 })
        #expect(cal.dateComponents([.year, .month, .day, .hour], from: t7.fireDate)
                == DateComponents(year: 2026, month: 10, day: 30, hour: 10))
        // The release-day beat is still 09:00 local on the far side of the shift.
        let dayOf = try #require(plans.first { $0.beat == .day })
        #expect(cal.dateComponents([.year, .month, .day, .hour], from: dayOf.fireDate)
                == DateComponents(year: 2026, month: 11, day: 6, hour: 9))
    }

    // MARK: Filtering

    @Test func pastBeatsAreExcluded() {
        // Three days out: the t7 beat is already behind us.
        let plans = plan([release("soon", inDays: 3)])
        #expect(plans.map(\.beat) == [.t1, .day])
        #expect(plans.allSatisfy { $0.fireDate > now })
    }

    @Test func aReleaseEarlierTodayKeepsNothingAndYesterdayKeepsNothing() {
        // now is noon; today's 09:00 beat has passed and so have the others.
        #expect(plan([release("today", inDays: 0)]).isEmpty)
        #expect(plan([release("yesterday", inDays: -1)]).isEmpty)
    }

    @Test func releasesBeyondTheHorizonAreNotScheduled() {
        #expect(plan([release("far", inDays: 120)]).isEmpty)
        #expect(!plan([release("near", inDays: 89)]).isEmpty)
    }

    @Test func unsubscribedReleasesAreAbsentAndAbsentRowsMeanSubscribed() {
        let releases = [release("on", inDays: 20), release("off", inDays: 20)]
        let plans = plan(releases, subscriptions: ["off": false])
        #expect(Set(plans.map(\.releaseID)) == ["on"])
        // An explicit true is the same as no row at all.
        let reSubscribed = plan(releases, subscriptions: ["off": true])
        #expect(Set(reSubscribed.map(\.releaseID)) == ["on", "off"])
    }

    // MARK: Ordering + cap

    @Test func plansAreAscendingByFireDate() {
        let releases = (0..<12).map { release("r\($0)", inDays: 80 - $0 * 5) }
        let plans = plan(releases)
        #expect(plans.map(\.fireDate) == plans.map(\.fireDate).sorted())
    }

    @Test func twoHundredReleasesStayUnderTheCapAndKeepTheNearestBeats() {
        let releases = (0..<200).map { release("r\($0)", inDays: 10 + ($0 % 60)) }
        let plans = plan(releases)
        #expect(plans.count == DropScheduler.maxPending)
        #expect(plans.count <= 48)
        #expect(Set(plans.map(\.id)).count == plans.count)
        // The cap keeps the earliest beats: nothing dropped fires before the
        // last one kept.
        let all = releases.flatMap { release in
            DropNotificationPlan.Beat.allCases.compactMap {
                DropScheduler.fireDate(for: release, beat: $0, calendar: cal)
            }
        }
        let lastKept = plans[plans.count - 1].fireDate
        #expect(all.filter { $0 > now && $0 < lastKept }.count < DropScheduler.maxPending)
    }

    // MARK: Copy

    @Test func copyIsAboutReleaseDatesNeverStock() {
        let plans = plan([release("a", inDays: 30)], favoriteCount: 3)
        for item in plans {
            let text = "\(item.title) \(item.body)".lowercased()
            #expect(!text.contains("stock"))
            #expect(!text.contains("in stock"))
            #expect(!text.contains("restock"))
            #expect(!text.contains("available now"))
            #expect(text.contains("releasing") || text.contains("due") || text.contains("out today"))
        }
        #expect(plans.allSatisfy { $0.body.contains("Delta Reign") })
    }

    @Test func theDayBeforeMentionsSavedShopsOnlyWhenThereAreSome() throws {
        let withStores = try #require(plan([release("a", inDays: 30)], favoriteCount: 3)
            .first { $0.beat == .t1 })
        #expect(withStores.body.contains("3 saved shops"))

        let single = try #require(plan([release("a", inDays: 30)], favoriteCount: 1)
            .first { $0.beat == .t1 })
        #expect(single.body.contains("1 saved shop"))
        #expect(!single.body.contains("shops"))

        let none = try #require(plan([release("a", inDays: 30)], favoriteCount: 0)
            .first { $0.beat == .t1 })
        #expect(!none.body.lowercased().contains("shop"))
        #expect(!none.body.lowercased().contains("saved"))
        // The other beats never mention stores at all.
        for item in plan([release("a", inDays: 30)], favoriteCount: 3) where item.beat != .t1 {
            #expect(!item.body.lowercased().contains("shop"))
        }
    }

    @Test func confirmedDatesDropTheHedge() throws {
        let expected = try #require(plan([release("a", inDays: 30)]).first)
        #expect(expected.body.contains("still expected"))
        let confirmed = try #require(plan([release("b", inDays: 30, confidence: .confirmed)]).first)
        #expect(!confirmed.body.contains("still expected"))
    }

    // MARK: Idempotence

    @Test func planningTwiceProducesTheSamePlan() {
        let releases = (0..<40).map { release("r\($0)", inDays: 5 + $0 * 2) }
        let subscriptions = ["r3": false, "r7": true]
        let first = plan(releases, subscriptions: subscriptions, favoriteCount: 2)
        let second = plan(releases, subscriptions: subscriptions, favoriteCount: 2)
        #expect(first == second)
        // Order of the input does not change the outcome.
        let shuffled = plan(releases.reversed(), subscriptions: subscriptions, favoriteCount: 2)
        #expect(first == shuffled)
    }
}
