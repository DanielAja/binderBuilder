//
//  InteractiveCardTests.swift
//  binderBuilderTests
//
//  The two pure pieces behind `interactiveCard()`: the tilt-to-haptic-tick
//  crossing math and the FoilTier -> UI band collapse. Both are nonisolated
//  value math with no view or generator involved, in the same spirit as
//  HoverCardTests.
//

import Testing
@testable import binderBuilder

struct InteractiveCardTests {

    // MARK: Tick crossing math

    /// A straight horizontal sweep, sampled every `step` degrees, far enough
    /// apart in time that the rate limiter never engages.
    private func sweep(to end: Double, step: Double, dt: Double = 1) -> [(x: Double, y: Double, time: Double)] {
        var path: [(x: Double, y: Double, time: Double)] = []
        var x = 0.0
        var t = 0.0
        while x < end - 1e-9 {
            path.append((x: x, y: 0, time: t))
            x += step
            t += dt
        }
        path.append((x: end, y: 0, time: t))
        return path
    }

    @Test func ticksOncePerFiveDegreesOfTravel() {
        // 20 degrees of travel in 1-degree samples = four 5-degree crossings.
        #expect(TiltTickTracker.tickCount(path: sweep(to: 20, step: 1)) == 4)
    }

    @Test func partialTravelBelowOneStepNeverTicks() {
        #expect(TiltTickTracker.tickCount(path: sweep(to: 4.9, step: 0.7)) == 0)
    }

    @Test func firstSampleOnlySeedsThePath() {
        // A single sample is a touch-down with no travel yet: no tick.
        #expect(TiltTickTracker.tickCount(path: [(x: 40, y: 40, time: 0)]) == 0)
    }

    @Test func travelAccumulatesRegardlessOfSampleSize() {
        // The same 15 degrees delivered coarsely or finely crosses the same
        // number of 5-degree marks.
        #expect(TiltTickTracker.tickCount(path: sweep(to: 15, step: 5)) == 3)
        #expect(TiltTickTracker.tickCount(path: sweep(to: 15, step: 0.25)) == 3)
    }

    @Test func diagonalTravelUsesStraightLineDistance() {
        // A 3-4-5 triangle: one step of exactly 5 degrees, so exactly one tick.
        let path = [(x: 0.0, y: 0.0, time: 0.0), (x: 3.0, y: 4.0, time: 1.0)]
        #expect(TiltTickTracker.tickCount(path: path) == 1)
    }

    @Test func backAndForthTravelStillTicks() {
        // Distance traveled, not distance from the origin: a wiggle that ends
        // where it started has still moved the card under the finger.
        let path = [
            (x: 0.0, y: 0.0, time: 0.0),
            (x: 6.0, y: 0.0, time: 1.0),
            (x: 0.0, y: 0.0, time: 2.0),
            (x: 6.0, y: 0.0, time: 3.0),
        ]
        #expect(TiltTickTracker.tickCount(path: path) == 3)
    }

    // MARK: Rate limiting

    @Test func rateLimiterSwallowsTicksArrivingTooFast() {
        // Identical 20-degree sweep, but every sample lands within the minimum
        // interval — the limiter has to collapse the burst.
        let fast = sweep(to: 20, step: 1, dt: TiltTickTracker.minInterval / 10)
        let slow = sweep(to: 20, step: 1, dt: 1)
        let fastTicks = TiltTickTracker.tickCount(path: fast)
        #expect(TiltTickTracker.tickCount(path: slow) == 4)
        #expect(fastTicks < 4)
        #expect(fastTicks >= 1)
    }

    @Test func rateLimiterCannotQueueADoubleTick() {
        // A huge jump swallowed by the limiter, then a long pause: the held
        // crossing fires once, not once per step it flew past.
        var tracker = TiltTickTracker()
        tracker.begin(x: 0, y: 0)
        _ = tracker.update(x: 5, y: 0, time: 0)          // first tick, opens the window
        #expect(tracker.update(x: 100, y: 0, time: 0) == false)  // swallowed
        #expect(tracker.update(x: 100, y: 0, time: 10) == true)  // the held crossing
        #expect(tracker.update(x: 100, y: 0, time: 20) == false) // nothing left over
    }

    @Test func beginResetsTheAccumulatorBetweenDrags() {
        var tracker = TiltTickTracker()
        tracker.begin(x: 0, y: 0)
        #expect(tracker.update(x: 4, y: 0, time: 0) == false)  // 4 degrees banked
        tracker.begin(x: 0, y: 0)                              // new drag
        #expect(tracker.update(x: 4, y: 0, time: 1) == false)  // bank did not carry
    }

    // MARK: Intensity

    @Test func zeroIntensityProducesNoTicks() {
        #expect(TiltTickTracker.tickCount(path: sweep(to: 200, step: 1), intensity: 0) == 0)
    }

    @Test func zeroIntensityStaysSilentOnEveryPath() {
        var tracker = TiltTickTracker(intensity: 0)
        tracker.begin(x: 0, y: 0)
        for i in 1...200 {
            #expect(tracker.update(x: Double(i) * 7, y: Double(i) * -3, time: Double(i)) == false)
        }
    }

    @Test func emptyPathIsSafe() {
        #expect(TiltTickTracker.tickCount(path: []) == 0)
    }

    // MARK: Tier -> band mapping

    @Test func everyFoilTierMapsToABand() {
        // Totality: the mapping is a `switch` with no default, so this mostly
        // guards against a future tier being added and silently defaulted.
        for tier in FoilTier.allCases {
            let band = FoilBand.band(for: tier)
            #expect(FoilBand.allCases.contains(band))
        }
        #expect(FoilTier.allCases.count == 9)
    }

    @Test func mappingIsStable() {
        #expect(FoilBand.band(for: .none) == .flat)
        #expect(FoilBand.band(for: .holoArt) == .subtle)
        #expect(FoilBand.band(for: .reverseInverse) == .subtle)
        #expect(FoilBand.band(for: .illustrationRare) == .subtle)
        #expect(FoilBand.band(for: .fullArtEtched) == .bright)
        #expect(FoilBand.band(for: .specialIllustrationRare) == .bright)
        #expect(FoilBand.band(for: .secretRainbow) == .bright)
        #expect(FoilBand.band(for: .goldHyper) == .gold)
        #expect(FoilBand.band(for: .megaHyperGold) == .gold)
    }

    @Test func everyBandIsReachableFromSomeTier() {
        let reached = Set(FoilTier.allCases.map { FoilBand.band(for: $0) })
        #expect(reached == Set(FoilBand.allCases))
    }

    @Test func onlyTheFlatBandIsSilent() {
        for band in FoilBand.allCases {
            #expect((band.sheen == 0) == (band == .flat))
        }
    }

    @Test func sheenRisesWithTheBand() {
        #expect(FoilBand.flat.sheen < FoilBand.subtle.sheen)
        #expect(FoilBand.subtle.sheen < FoilBand.bright.sheen)
        #expect(FoilBand.bright.sheen <= FoilBand.gold.sheen)
    }

    @Test func onlyTheLoudBandsSweep() {
        #expect(FoilBand.flat.sweeps == false)
        #expect(FoilBand.subtle.sweeps == false)
        #expect(FoilBand.bright.sweeps)
        #expect(FoilBand.gold.sweeps)
    }

    @Test func aSweepFitsInsideItsPeriod() {
        #expect(FoilBand.sweepDuration < FoilBand.sweepPeriod)
    }

    // MARK: Resolution from a card

    @Test func rarityAndVariantResolveThroughToABand() {
        // The whole chain the UI convenience uses: rarity string -> tier -> band.
        #expect(FoilBand.band(for: .resolve(rarity: "Common", variant: .normal)) == .flat)
        #expect(FoilBand.band(for: .resolve(rarity: "Common", variant: .reverse)) == .subtle)
        #expect(FoilBand.band(for: .resolve(rarity: "Rare Holo", variant: .normal)) == .subtle)
        #expect(FoilBand.band(for: .resolve(rarity: "Special illustration rare", variant: .holo)) == .bright)
        #expect(FoilBand.band(for: .resolve(rarity: "Hyper rare", variant: .normal)) == .gold)
    }

    @Test func unknownRarityFallsBackToTheVariant() {
        #expect(FoilBand.band(for: .resolve(rarity: "Some Future Rarity", variant: .normal)) == .flat)
        #expect(FoilBand.band(for: .resolve(rarity: nil, variant: .holo)) == .subtle)
    }
}
