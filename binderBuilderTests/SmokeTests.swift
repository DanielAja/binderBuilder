//
//  SmokeTests.swift
//  binderBuilderTests
//

import Testing
import GRDB
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
