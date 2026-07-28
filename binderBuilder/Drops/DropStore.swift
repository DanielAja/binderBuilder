//
//  DropStore.swift
//  binderBuilder
//
//  The upcoming-release calendar as UI state: the bundled releases plus the
//  user's per-release reminder toggles. Cheap init, `load()` does the bundle
//  decode and the drop_subscription read off the main thread.
//

import Foundation
import Observation
import os

@MainActor @Observable final class DropStore {
    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.aja.binderBuilder", category: "DropStore")

    @ObservationIgnored private let database: UserDatabase
    @ObservationIgnored private let bundle: Bundle

    /// Every curated release, ascending by expected date.
    private(set) var releases: [UpcomingRelease] = []
    /// Deviations from the subscribed-by-default rule, keyed by release id.
    private(set) var subscriptions: [String: Bool] = [:]
    private(set) var isLoaded = false
    private(set) var changeToken = 0

    init(database: UserDatabase, bundle: Bundle = .main) {
        self.database = database
        self.bundle = bundle
    }

    /// Loads the bundled calendar and the subscription overrides off the main
    /// thread (called from AppEnvironment.prepare()).
    func load() async {
        let bundle = self.bundle
        let database = self.database
        let loaded = await Task.detached(priority: .userInitiated) { () -> ([UpcomingRelease], [String: Bool]) in
            (ReleaseCalendar.load(bundle: bundle).releases, database.dropSubscriptions())
        }.value
        releases = loaded.0
        subscriptions = loaded.1
        isLoaded = true
        changeToken &+= 1
    }

    /// Releases due inside the reminder horizon, ascending.
    func upcoming(now: Date = Date(), within horizon: TimeInterval = ReleaseCalendar.defaultHorizon) -> [UpcomingRelease] {
        ReleaseCalendar.upcoming(releases, now: now, within: horizon)
    }

    func release(id: String) -> UpcomingRelease? {
        releases.first { $0.id == id }
    }

    /// Absent means subscribed — the table only records deviations.
    func isSubscribed(_ releaseID: String) -> Bool {
        subscriptions[releaseID] ?? true
    }

    func setSubscribed(_ subscribed: Bool, for releaseID: String) {
        do {
            try database.setDropSubscription(releaseID, enabled: subscribed)
            subscriptions[releaseID] = subscribed
            changeToken &+= 1
        } catch {
            Self.logger.error("setSubscribed failed: \(String(describing: error))")
        }
    }
}
