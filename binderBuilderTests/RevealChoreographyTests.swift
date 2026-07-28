//
//  RevealChoreographyTests.swift
//  binderBuilderTests
//
//  The reveal's timing contract: price -> tier thresholds, beats that never
//  overlap, a glint that lands inside its own flip, and a Reduce Motion pass
//  that changes how a card turns without changing the rhythm it turns to.
//

import Testing
import Foundation
@testable import binderBuilder

@Suite struct RevealChoreographyTests {
    // MARK: - Tiers

    @Test func tierThresholdsAreHalfOpen() {
        #expect(RevealTier.tier(forPrice: nil) == .common)
        #expect(RevealTier.tier(forPrice: 0) == .common)
        #expect(RevealTier.tier(forPrice: 4.99) == .common)
        #expect(RevealTier.tier(forPrice: 5.00) == .notable)
        #expect(RevealTier.tier(forPrice: 24.99) == .notable)
        #expect(RevealTier.tier(forPrice: 25.00) == .chase)
        #expect(RevealTier.tier(forPrice: 999) == .chase)
    }

    @Test func itemTierFollowsItsPrice() {
        #expect(RevealItem(cardID: "a", name: "A", imageBase: nil, price: nil).tier == .common)
        #expect(RevealItem(cardID: "b", name: "B", imageBase: nil, price: 12).tier == .notable)
        #expect(RevealItem(cardID: "c", name: "C", imageBase: nil, price: 40).tier == .chase)
    }

    @Test func itemsAreUniquePerAppearance() {
        // The same card scanned twice must reveal twice, so identity can't be
        // the card id.
        let first = RevealItem(cardID: "base1-4", name: "Card", imageBase: nil, price: 1)
        let second = RevealItem(cardID: "base1-4", name: "Card", imageBase: nil, price: 1)
        #expect(first.id != second.id)
    }

    // MARK: - Timeline

    @Test func emptyBatchProducesNoBeats() {
        #expect(RevealChoreography.timeline([], reduceMotion: false).isEmpty)
        #expect(RevealChoreography.timeline([], reduceMotion: true).isEmpty)
    }

    @Test(arguments: [false, true])
    func startsAreMonotonicAndNonOverlapping(_ reduceMotion: Bool) {
        let tiers: [RevealTier] = [.common, .chase, .notable, .common, .chase]
        let beats = RevealChoreography.timeline(tiers, reduceMotion: reduceMotion)
        let turn = reduceMotion ? RevealChoreography.crossfade : RevealChoreography.flip

        #expect(beats.map(\.index) == Array(tiers.indices))
        #expect(beats.first?.start == .zero)
        for (previous, next) in zip(beats, beats.dropFirst()) {
            // A card can't rip until the one before it has finished turning
            // and held — and the gap on top of that.
            #expect(next.start == previous.start + turn + previous.hang + RevealChoreography.gap)
            #expect(next.start > previous.start)
        }
    }

    @Test func glintLandsInsideTheFlipWindow() {
        let beats = RevealChoreography.timeline([.common, .notable, .chase], reduceMotion: false)
        for beat in beats {
            #expect(beat.flipStart == beat.start)
            #expect(beat.glintStart >= beat.flipStart)
            #expect(beat.glintStart <= beat.flipStart + RevealChoreography.flip)
            // 150–400 ms: it starts as the face swings toward the viewer and
            // trails 20 ms past the flip so the sheen settles on a still card.
            #expect(beat.glintStart == beat.start + .milliseconds(150))
        }
    }

    @Test func hangsGrowWithTier() {
        let beats = RevealChoreography.timeline([.common, .notable, .chase], reduceMotion: false)
        #expect(beats.map(\.hang) == [.milliseconds(380), .milliseconds(520), .milliseconds(1400)])
    }

    @Test func onlyChaseWaitsForATap() {
        let beats = RevealChoreography.timeline([.common, .notable, .chase], reduceMotion: false)
        #expect(beats.map(\.requiresTap) == [false, false, true])
    }

    // MARK: - Reduce Motion

    @Test func reduceMotionPreservesHangsAndTapGates() {
        let tiers: [RevealTier] = [.chase, .common, .notable, .chase, .common]
        let motion = RevealChoreography.timeline(tiers, reduceMotion: false)
        let reduced = RevealChoreography.timeline(tiers, reduceMotion: true)

        #expect(reduced.count == motion.count)
        #expect(reduced.map(\.hang) == motion.map(\.hang))
        #expect(reduced.map(\.requiresTap) == motion.map(\.requiresTap))
        #expect(reduced.map(\.tier) == motion.map(\.tier))
    }

    @Test func reduceMotionCollapsesFlipAndGlintOntoTheStart() {
        let beats = RevealChoreography.timeline([.common, .chase], reduceMotion: true)
        for beat in beats {
            #expect(beat.flipStart == beat.start)
            #expect(beat.glintStart == beat.start)
        }
    }

    @Test func reduceMotionRunsShorterOnlyBecauseTheTurnIsShorter() {
        let tiers: [RevealTier] = [.common, .notable]
        let motion = RevealChoreography.timeline(tiers, reduceMotion: false)
        let reduced = RevealChoreography.timeline(tiers, reduceMotion: true)
        let saved = RevealChoreography.flip - RevealChoreography.crossfade
        #expect(reduced[1].start == motion[1].start - saved)
    }

    // MARK: - Intensity

    @Test func burstIntensityScalesWithTier() {
        #expect(RevealChoreography.burstIntensity(for: .common) == 40)
        #expect(RevealChoreography.burstIntensity(for: .notable) == 90)
        #expect(RevealChoreography.burstIntensity(for: .chase) == 180)
    }
}
