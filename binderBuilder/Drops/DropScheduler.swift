//
//  DropScheduler.swift
//  binderBuilder
//
//  Turns the curated release calendar into local release-date reminders.
//  `plan` is pure (and unit-tested) so the beat/horizon/cap rules can be
//  reasoned about without UserNotifications; `reconcile` is the thin apply
//  step: cancel every `drop-` request, then re-add the current plan.
//
//  These are release-date reminders only — we never claim to know a store's
//  stock.
//

import Foundation
import OSLog

/// One scheduled reminder for one release.
nonisolated struct DropNotificationPlan: Identifiable, Hashable, Sendable {
    /// The three beats around a release day.
    nonisolated enum Beat: String, Sendable, CaseIterable {
        case t7   // one week out, 10:00
        case t1   // day before, 18:00
        case day  // release day, 09:00

        var dayOffset: Int {
            switch self {
            case .t7: -7
            case .t1: -1
            case .day: 0
            }
        }

        var hour: Int {
            switch self {
            case .t7: 10
            case .t1: 18
            case .day: 9
            }
        }
    }

    /// `drop-<releaseID>-<beat>`; the `drop-` prefix is what reconcile clears.
    var id: String
    var releaseID: String
    var beat: Beat
    var title: String
    var body: String
    /// When it fires, resolved in the planning calendar's zone.
    var fireDate: Date
    /// The same instant as calendar components, for UNCalendarNotificationTrigger.
    var dateComponents: DateComponents
}

nonisolated enum DropScheduler {
    private static let logger = Logger(subsystem: "com.aja.binderBuilder", category: "DropScheduler")

    /// Every reminder we own shares this prefix.
    static let identifierPrefix = "drop-"
    /// Hard ceiling on pending requests, with headroom under iOS's 64.
    static let maxPending = 48
    /// We never schedule further out than this.
    static let horizon = ReleaseCalendar.defaultHorizon

    // MARK: - Pure planning

    /// The reminders that should be pending right now.
    ///
    /// - `subscriptions` stores deviations only: an absent release id is
    ///   subscribed, an explicit `false` is not.
    /// - Beats already in the past are dropped, as is anything past the 90-day
    ///   horizon; the result is ascending by fire date and capped at
    ///   `maxPending` (nearest beats win).
    /// - `favoriteCount` only colours the t1 copy; 0 omits the store phrase.
    static func plan(
        releases: [UpcomingRelease],
        subscriptions: [String: Bool],
        now: Date,
        favoriteCount: Int,
        calendar: Calendar = .current
    ) -> [DropNotificationPlan] {
        // Upper bound only: a release earlier today is still worth its 09:00
        // beat, and anything fully behind us loses every beat to `fire > now`.
        let cutoff = now.addingTimeInterval(horizon)
        let inHorizon = releases.filter { $0.expectedDate <= cutoff }
        var plans: [DropNotificationPlan] = []
        for release in inHorizon where subscriptions[release.id] ?? true {
            for beat in DropNotificationPlan.Beat.allCases {
                guard let fire = fireDate(for: release, beat: beat, calendar: calendar), fire > now
                else { continue }
                plans.append(DropNotificationPlan(
                    id: "\(identifierPrefix)\(release.id)-\(beat.rawValue)",
                    releaseID: release.id,
                    beat: beat,
                    title: title(for: beat),
                    body: body(for: release, beat: beat, favoriteCount: favoriteCount, calendar: calendar),
                    fireDate: fire,
                    dateComponents: calendar.dateComponents(
                        [.year, .month, .day, .hour, .minute], from: fire)))
            }
        }
        plans.sort { ($0.fireDate, $0.id) < ($1.fireDate, $1.id) }
        return Array(plans.prefix(maxPending))
    }

    /// The instant a beat fires: whole-day arithmetic off the release day (so
    /// DST never shifts us onto the wrong date) at the beat's local hour.
    static func fireDate(
        for release: UpcomingRelease,
        beat: DropNotificationPlan.Beat,
        calendar: Calendar
    ) -> Date? {
        let releaseDay = calendar.startOfDay(for: release.expectedDate)
        guard let day = calendar.date(byAdding: .day, value: beat.dayOffset, to: releaseDay)
        else { return nil }
        return calendar.date(bySettingHour: beat.hour, minute: 0, second: 0, of: day)
    }

    // MARK: - Copy

    static func title(for beat: DropNotificationPlan.Beat) -> String {
        switch beat {
        case .t7: "Releasing in a week"
        case .t1: "Releasing tomorrow"
        case .day: "Releasing today"
        }
    }

    static func body(
        for release: UpcomingRelease,
        beat: DropNotificationPlan.Beat,
        favoriteCount: Int,
        calendar: Calendar
    ) -> String {
        let day = dayText(release.expectedDate, calendar: calendar)
        let hedge = release.confidence == .confirmed ? "" : " (date still expected)"
        switch beat {
        case .t7:
            return "\(release.name) — \(release.seriesName) — is due \(day)\(hedge)."
        case .t1:
            let lead = "\(release.name) is due \(day)\(hedge)."
            guard favoriteCount > 0 else { return lead }
            let noun = favoriteCount == 1 ? "shop" : "shops"
            return "\(lead) You have \(favoriteCount) saved \(noun) to try."
        case .day:
            return "\(release.name) — \(release.seriesName) — is out today."
        }
    }

    private static func dayText(_ date: Date, calendar: Calendar) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    // MARK: - Apply

    /// Rebuilds the pending reminder set from scratch: cancel everything under
    /// the `drop-` prefix, then schedule the current plan. Idempotent, so it is
    /// safe to run on every alert pass.
    @MainActor
    static func reconcile(env: AppEnvironment, calendar: Calendar = .current, now: Date = Date()) async {
        guard env.settings.dropAlertsEnabled else {
            await NotificationService.cancel(idsWithPrefix: identifierPrefix)
            return
        }
        guard await NotificationService.isAuthorized() else { return }

        let releaseCalendar = ReleaseCalendar.load(calendar: calendar)
        // known_set is the confirmation signal: AlertChecker refreshes it from
        // TCGdex just before this runs, so no second network round-trip.
        let confirmed = Set(
            releaseCalendar
                .promoted(calendar: calendar, remoteSetIDs: env.userDatabase.knownSetIDs(), now: now)
                .map(\.id))
        let plans = plan(
            releases: releaseCalendar.releases.filter { !confirmed.contains($0.id) },
            subscriptions: env.userDatabase.dropSubscriptions(),
            now: now,
            favoriteCount: env.userDatabase.dropFavoriteStoreCount(),
            calendar: calendar)

        await NotificationService.cancel(idsWithPrefix: identifierPrefix)
        for item in plans {
            await NotificationService.schedule(
                id: item.id, title: item.title, body: item.body, at: item.dateComponents)
        }
        logger.info("scheduled \(plans.count, privacy: .public) drop reminders (\(confirmed.count, privacy: .public) confirmed, skipped)")
    }
}
