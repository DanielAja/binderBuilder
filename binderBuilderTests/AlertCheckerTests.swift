//
//  AlertCheckerTests.swift
//  binderBuilderTests
//
//  Pure alert trigger + new-release diff logic.
//

import Testing
@testable import binderBuilder

struct AlertCheckerTests {
    @Test func belowTargetTriggersAtOrUnderTarget() {
        #expect(AlertChecker.isTriggered(kind: .belowTarget, threshold: 100, baseline: nil, price: 100))
        #expect(AlertChecker.isTriggered(kind: .belowTarget, threshold: 100, baseline: nil, price: 80))
        #expect(!AlertChecker.isTriggered(kind: .belowTarget, threshold: 100, baseline: nil, price: 120))
    }

    @Test func percentDropTriggersFromBaseline() {
        // 20% drop from 200 -> trigger at <= 160.
        #expect(AlertChecker.isTriggered(kind: .percentDrop, threshold: 20, baseline: 200, price: 160))
        #expect(AlertChecker.isTriggered(kind: .percentDrop, threshold: 20, baseline: 200, price: 150))
        #expect(!AlertChecker.isTriggered(kind: .percentDrop, threshold: 20, baseline: 200, price: 170))
        // No baseline -> never triggers.
        #expect(!AlertChecker.isTriggered(kind: .percentDrop, threshold: 20, baseline: nil, price: 1))
    }

    @Test func newSetDiff() {
        let remote = ["base1", "swsh9", "sv10", "sv11"]
        let known: Set<String> = ["base1", "swsh9", "sv10"]
        #expect(AlertChecker.newSetIDs(remote: remote, known: known) == ["sv11"])
        #expect(AlertChecker.newSetIDs(remote: remote, known: Set(remote)).isEmpty)
    }
}
