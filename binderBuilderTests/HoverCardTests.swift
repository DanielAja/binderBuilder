//
//  HoverCardTests.swift
//  binderBuilderTests
//
//  The idle-sway math behind `hoverCard()` — factored into a pure,
//  nonisolated helper so it's testable without a live TimelineView.
//

import SwiftUI
import Testing
@testable import binderBuilder

struct HoverCardTests {
    @Test func zeroIntensityYieldsNoMotion() {
        for t in stride(from: 0.0, through: 40.0, by: 5.0) {
            let angles = HoverCardMath.angles(at: t, intensity: 0)
            #expect(angles.x.degrees == 0)
            #expect(angles.y.degrees == 0)
            #expect(angles.bob == 0)
        }
    }

    @Test func amplitudesStayWithinDocumentedMaxima() {
        for i in stride(from: 0, through: 2000, by: 7) {
            let t = Double(i) * 0.1
            let angles = HoverCardMath.angles(at: t, intensity: 1)
            #expect(abs(angles.x.degrees) <= HoverCardMath.maxTiltX + 1e-9)
            #expect(abs(angles.y.degrees) <= HoverCardMath.maxTiltY + 1e-9)
            #expect(abs(angles.bob) <= HoverCardMath.maxBob + 1e-9)
        }
    }

    @Test func intensityScalesLinearly() {
        let t = 12.7
        let full = HoverCardMath.angles(at: t, intensity: 1)
        let half = HoverCardMath.angles(at: t, intensity: 0.5)
        let double = HoverCardMath.angles(at: t, intensity: 2)

        #expect(abs(half.x.degrees - full.x.degrees * 0.5) < 1e-9)
        #expect(abs(half.y.degrees - full.y.degrees * 0.5) < 1e-9)
        #expect(abs(half.bob - full.bob * 0.5) < 1e-9)

        #expect(abs(double.x.degrees - full.x.degrees * 2) < 1e-9)
        #expect(abs(double.y.degrees - full.y.degrees * 2) < 1e-9)
        #expect(abs(double.bob - full.bob * 2) < 1e-9)
    }

    @Test func xAxisRepeatsAtItsDocumentedPeriod() {
        let t0 = 3.3
        let a = HoverCardMath.angles(at: t0, intensity: 1)
        let b = HoverCardMath.angles(at: t0 + HoverCardMath.periodX, intensity: 1)
        #expect(abs(a.x.degrees - b.x.degrees) < 1e-6)
    }

    @Test func yAxisRepeatsAtItsDocumentedPeriod() {
        let t0 = 9.1
        let a = HoverCardMath.angles(at: t0, intensity: 1)
        let b = HoverCardMath.angles(at: t0 + HoverCardMath.periodY, intensity: 1)
        #expect(abs(a.y.degrees - b.y.degrees) < 1e-6)
    }

    @Test func bobRepeatsAtItsDocumentedPeriod() {
        let t0 = 1.4
        let a = HoverCardMath.angles(at: t0, intensity: 1)
        let b = HoverCardMath.angles(at: t0 + HoverCardMath.periodBob, intensity: 1)
        #expect(abs(a.bob - b.bob) < 1e-6)
    }

    @Test func axesAreOutOfPhase() {
        // At t = 0 the x axis is exactly at its zero crossing; the y axis,
        // carrying a phase offset, should not be — that offset is what
        // keeps the sway from reading as a single mechanical wobble.
        let angles = HoverCardMath.angles(at: 0, intensity: 1)
        #expect(angles.x.degrees == 0)
        #expect(angles.y.degrees != 0)
    }

    @Test func zeroTimeIsWithinBoundsAndDeterministic() {
        let a = HoverCardMath.angles(at: 0, intensity: 1)
        let b = HoverCardMath.angles(at: 0, intensity: 1)
        #expect(a.x.degrees == b.x.degrees)
        #expect(a.y.degrees == b.y.degrees)
        #expect(a.bob == b.bob)
    }
}
