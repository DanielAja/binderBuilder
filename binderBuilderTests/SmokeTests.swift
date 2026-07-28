//
//  SmokeTests.swift
//  binderBuilderTests
//

import SwiftUI
import Testing
import GRDB
import UIKit
@testable import binderBuilder

struct SmokeTests {
    @Test func grdbLinksAndOpensInMemoryDatabase() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE t (id INTEGER PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO t (id) VALUES (1)")
        }
        let count = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM t")
        }
        #expect(count == 1)
    }

    @Test func debugLaunchStateParsesArguments() {
        let state = DebugLaunchState(arguments: [
            "app", "-uiState", "binderOpen", "-curl", "0.5",
            "-tilt", "0.2,-0.1", "-deformer", "cpu",
        ])
        #expect(state.uiState == .binderOpen)
        #expect(state.curl == 0.5)
        #expect(state.tilt == SIMD2<Float>(0.2, -0.1))
        #expect(state.deformer == .cpu)
    }
}

/// Renders real top-level views against a real `AppEnvironment` (hosted-app
/// test target, so bundled/on-disk resources resolve) purely to catch
/// force-unwrap-class crashes on first layout — not a snapshot/behavior test.
@MainActor
struct HomeViewSmokeTests {
    @Test func rendersWithEmptyRecentPulls() {
        let env = AppEnvironment()
        // Deliberately skipping env.prepare(): CollectionStatsStore starts
        // with `recent`/`setProgress`/`topValuable` all empty, which is
        // exactly the "no Recent Pulls strip yet" case this guards.
        #expect(env.stats.recent.isEmpty)
        let host = UIHostingController(rootView: HomeView(env: env, selectedTab: .constant(.home)))
        host.loadViewIfNeeded()
        _ = host.view
    }
}

@MainActor
struct DropsViewSmokeTests {
    @Test func rendersWithEmptyStoresAndLocationNotAuthorized() {
        let env = AppEnvironment()
        // Fresh env: no favorite stores saved yet, and location permission is
        // not authorized in the test host — exactly the "nothing saved, no
        // nearby search yet" case both sections need to handle gracefully.
        let host = UIHostingController(rootView: NavigationStack { DropsView(env: env) })
        host.loadViewIfNeeded()
        _ = host.view
    }
}
