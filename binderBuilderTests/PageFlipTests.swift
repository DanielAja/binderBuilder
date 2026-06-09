//
//  PageFlipTests.swift
//  binderBuilderTests
//
//  Unit tests for the interactive page flip: critically-damped FlipSpring,
//  occupancy-aware dynamics (massFactor/omega/sag), page-pool rebinding
//  math, sag/sway uniform packing, the full-flip progress parameterization,
//  and the sag term in the CurlFunction CPU twin.
//

import Foundation
import Testing
import simd
@testable import binderBuilder

struct FlipSpringTests {
    @Test func convergesToTargetOneWithoutOvershoot() {
        var spring = FlipSpring(t: 0.3, velocity: 0, target: 1, omega: 10)
        var maxT: Float = spring.t
        var steps = 0
        while !spring.isSettled && steps < 10_000 {
            spring.step(dt: 1 / 120)
            maxT = max(maxT, spring.t)
            steps += 1
        }
        #expect(spring.isSettled)
        // Critically damped from rest: monotonic approach, never overshoots.
        #expect(maxT <= 1.0 + 1e-4)
        #expect(abs(spring.t - 1) < FlipSpring.settleDistance)
        // Settles in a sensible time (~6.6/omega s): well under 2 s here.
        #expect(Float(steps) / 120 < 2)
    }

    @Test func convergesToTargetZero() {
        var spring = FlipSpring(t: 0.62, velocity: -0.5, target: 0, omega: 8)
        var steps = 0
        while !spring.isSettled && steps < 10_000 {
            spring.step(dt: 1 / 120)
            steps += 1
        }
        #expect(spring.isSettled)
        #expect(abs(spring.t) < FlipSpring.settleDistance)
    }

    @Test func analyticStepIsStableForLargeDt() {
        // The closed-form step cannot blow up even with a huge frame hitch.
        var spring = FlipSpring(t: 0, velocity: 5, target: 1, omega: 12)
        spring.step(dt: 0.5)
        #expect(spring.t.isFinite && abs(spring.t) < 3)
        spring.step(dt: 2.0)
        #expect(abs(spring.t - 1) < 0.01)
    }

    @Test func heavierPagesSettleSlower() {
        func settleSteps(omega: Float) -> Int {
            var spring = FlipSpring(t: 0, velocity: 1.5, target: 1, omega: omega)
            var steps = 0
            while !spring.isSettled && steps < 100_000 {
                spring.step(dt: 1 / 120)
                steps += 1
            }
            return steps
        }
        let light = settleSteps(omega: PageDynamics.omega(occupiedSlots: 0))
        let heavy = settleSteps(omega: PageDynamics.omega(occupiedSlots: 18))
        #expect(heavy > light)
    }
}

struct PageDynamicsTests {
    @Test func massFactorMatchesSpec() {
        #expect(PageDynamics.massFactor(occupiedSlots: 0) == 1)
        #expect(abs(PageDynamics.massFactor(occupiedSlots: 18) - 2.44) < 1e-5)
        #expect(abs(PageDynamics.massFactor(occupiedSlots: 5) - 1.4) < 1e-5)
    }

    @Test func omegaScalesInverseSquareRootOfMass() {
        let empty = PageDynamics.omega(occupiedSlots: 0)
        #expect(abs(empty - PageDynamics.omega0) < 1e-5)
        let full = PageDynamics.omega(occupiedSlots: 18)
        #expect(abs(full - PageDynamics.omega0 / sqrt(2.44)) < 1e-4)
    }

    @Test func sagIsZeroAtBothRestPosesAndPeaksMidFlip() {
        #expect(PageDynamics.sag(occupiedSlots: 18, t: 0) == 0)
        #expect(abs(PageDynamics.sag(occupiedSlots: 18, t: 1)) < 1e-6)
        let mid = PageDynamics.sag(occupiedSlots: 18, t: 0.5)
        #expect(abs(mid - min(CurlParams.maxSag, 18 * PageDynamics.sagPerSlot)) < 1e-6)
        #expect(PageDynamics.sag(occupiedSlots: 0, t: 0.5) == 0)
        // More cards, more droop.
        #expect(PageDynamics.sag(occupiedSlots: 12, t: 0.5) > PageDynamics.sag(occupiedSlots: 3, t: 0.5))
    }
}

struct PagePoolTests {
    @Test func boundSheetsAroundFirstSpreads() {
        #expect(PagePool.boundSheets(spread: 0, sheetCount: 10) == [0, 1])
        #expect(PagePool.boundSheets(spread: 1, sheetCount: 10) == [0, 1, 2])
        #expect(PagePool.boundSheets(spread: 2, sheetCount: 10) == [0, 1, 2, 3])
    }

    @Test func boundSheetsMidAndLastSpreads() {
        #expect(PagePool.boundSheets(spread: 5, sheetCount: 10) == [3, 4, 5, 6])
        #expect(PagePool.boundSheets(spread: 9, sheetCount: 10) == [7, 8, 9])
        #expect(PagePool.boundSheets(spread: 10, sheetCount: 10) == [8, 9])
    }

    @Test func boundSheetsDegenerateBinders() {
        #expect(PagePool.boundSheets(spread: 0, sheetCount: 0) == [])
        #expect(PagePool.boundSheets(spread: 0, sheetCount: 1) == [0])
        #expect(PagePool.boundSheets(spread: 1, sheetCount: 1) == [0])
    }

    @Test func poolSlotsAreDistinctWithinEveryWindow() {
        for spread in 0...10 {
            let bound = PagePool.boundSheets(spread: spread, sheetCount: 10)
            let slots = bound.map(PagePool.poolSlot(forSheet:))
            #expect(Set(slots).count == bound.count, "spread \(spread): \(slots)")
        }
    }

    @Test func sheetsKeepTheirPoolSlotAcrossNeighboringSpreads() {
        // Sheet 4 is bound at spreads 3...6; same entity throughout.
        let slots = (3...6).map { spread -> Int in
            #expect(PagePool.boundSheets(spread: spread, sheetCount: 10).contains(4))
            return PagePool.poolSlot(forSheet: 4)
        }
        #expect(Set(slots).count == 1)
    }

    @Test func restProgressAndStackLayers() {
        // At spread 5: sheets 3,4 rest flipped (left), 5,6 unflipped (right).
        #expect(PagePool.restProgress(sheet: 4, spread: 5) == 1)
        #expect(PagePool.restProgress(sheet: 5, spread: 5) == 0)
        #expect(PagePool.stackLayer(sheet: 4, spread: 5) == 0) // left top
        #expect(PagePool.stackLayer(sheet: 3, spread: 5) == 1)
        #expect(PagePool.stackLayer(sheet: 5, spread: 5) == 0) // right top
        #expect(PagePool.stackLayer(sheet: 6, spread: 5) == 1)
    }

    @Test func sheetDistribution() {
        #expect(PagePool.sheetsOnLeft(spread: 0) == 0)
        #expect(PagePool.sheetsOnRight(spread: 0, sheetCount: 10) == 10)
        #expect(PagePool.sheetsOnLeft(spread: 7) == 7)
        #expect(PagePool.sheetsOnRight(spread: 7, sheetCount: 10) == 3)
        #expect(PagePool.sheetsOnRight(spread: 10, sheetCount: 10) == 0)
    }
}

struct SagPackingTests {
    @Test func roundTripsWithinQuantization() {
        let sagQuantum = CurlParams.maxSag / 1023
        let swayQuantum: Float = 2.0 / 1023
        for (sag, sway) in [(Float(0), Float(0)), (0.013, -0.4), (0.0007, 0.99), (0.02, -1), (0.0042, 0.25)] {
            let packed = CurlParams.packSagSway(sag: sag, sway: sway)
            let (outSag, outSway) = CurlParams.unpackSagSway(packed)
            #expect(abs(outSag - sag) <= sagQuantum, "sag \(sag) -> \(outSag)")
            #expect(abs(outSway - sway) <= swayQuantum, "sway \(sway) -> \(outSway)")
        }
    }

    @Test func packedValueIsExactlyRepresentableAndClamped() {
        // Extremes stay within 2^20 - 1 (exact in Float32) and clamp.
        let top = CurlParams.packSagSway(sag: 99, sway: 99)
        #expect(top == Float((1023 << 10) | 1023))
        let bottom = CurlParams.packSagSway(sag: -1, sway: -99)
        #expect(bottom == 0)
    }

    @Test func float4RoundTripCanonicalizesSag() {
        let params = CurlParams(d: 0.08, r: 0.045, psi: 0.2, sag: 0.0123, sway: 0.5)
        let restored = CurlParams(float4: params.float4)
        #expect(restored.d == params.d)
        #expect(restored.r == params.r)
        #expect(restored.psi == params.psi)
        #expect(abs(restored.sag - params.sag) <= CurlParams.maxSag / 1023)
        // Canonicalization is idempotent: pack(unpack(x)) == x.
        let again = CurlParams(float4: restored.float4)
        #expect(again == restored)
    }
}

struct FlipProgressTests {
    @Test func progressOneRestsFlatMirroredOnTheLeft() {
        let params = CurlParams.progress(1)
        #expect(params.d == 0)
        #expect(abs(params.r - CurlParams.restRadius) < 1e-6)
        #expect(abs(params.psi) < 1e-6)
        // The free edge ends up at roughly -pageWidth (mirrored), barely lifted.
        let out = CurlFunction.deform(
            position: SIMD3<Float>(PageMesh.width, 0.15, 0),
            normal: SIMD3<Float>(0, 0, 1),
            params: params
        )
        #expect(abs(out.position.x + (PageMesh.width - .pi * CurlParams.restRadius)) < 1e-4)
        #expect(out.position.z <= 2 * CurlParams.restRadius + 1e-5)
        // Normal has flipped: the page is upside down.
        #expect(out.normal.z < -0.99)
    }

    @Test func progressIsContinuousAtThePhaseBoundary() {
        let a = CurlParams.progress(0.4999)
        let b = CurlParams.progress(0.5001)
        #expect(abs(a.d - b.d) < 1e-3)
        #expect(abs(a.r - b.r) < 1e-3)
        #expect(abs(a.psi - b.psi) < 1e-3)
    }

    @Test func phaseAMovesCurlTowardSpineAtConstantRadius() {
        var lastD = Float.greatestFiniteMagnitude
        for c in stride(from: Float(0), through: 0.5, by: 0.05) {
            let p = CurlParams.progress(c)
            #expect(p.d <= lastD)
            #expect(abs(p.r - 0.05) < 1e-6)
            lastD = p.d
        }
        #expect(CurlParams.progress(0.5).d < 1e-6)
    }
}

struct CurlSagTests {
    @Test func zeroSagMatchesLegacyDeformation() {
        let plain = CurlParams(d: 0.06, r: 0.05, psi: 0.2)
        for x in stride(from: Float(0), through: PageMesh.width, by: PageMesh.width / 8) {
            let p = SIMD3<Float>(x, 0.1, 0)
            let a = CurlFunction.deform(position: p, normal: SIMD3<Float>(0, 0, 1), params: plain)
            var sagged = plain
            sagged.sag = 0
            let b = CurlFunction.deform(position: p, normal: SIMD3<Float>(0, 0, 1), params: sagged)
            #expect(a.position == b.position)
        }
    }

    @Test func liftedMidPageMaterialDroopsBySag() {
        // A vertex a quarter-turn up the cylinder, near the middle of the
        // page width, has full lift: droop == sag * bell(u).
        let d: Float = 0.06
        let r: Float = 0.05
        let x = d + .pi * r / 2 // mid-page-ish (0.1385 of 0.24)
        let noSag = CurlFunction.deform(
            position: SIMD3<Float>(x, 0.1, 0), normal: SIMD3<Float>(0, 0, 1),
            params: CurlParams(d: d, r: r, psi: 0)
        )
        let sag: Float = 0.01
        let withSag = CurlFunction.deform(
            position: SIMD3<Float>(x, 0.1, 0), normal: SIMD3<Float>(0, 0, 1),
            params: CurlParams(d: d, r: r, psi: 0, sag: sag)
        )
        let u = x / PageMesh.width
        let expectedDroop = sag * 4 * u * (1 - u) // lift saturates at z >= r
        #expect(abs((noSag.position.z - withSag.position.z) - expectedDroop) < 1e-5)
        #expect(withSag.position.x == noSag.position.x)
        #expect(withSag.position.y == noSag.position.y)
    }

    @Test func flatMaterialNeverSinksBelowTheStack() {
        // Material on the spine side of the curl line has zero lift: sag
        // cannot push it through the page stack.
        let params = CurlParams(d: 0.12, r: 0.04, psi: 0, sag: 0.02)
        for x in stride(from: Float(0), through: 0.12, by: 0.02) {
            let out = CurlFunction.deform(
                position: SIMD3<Float>(x, 0.15, 0), normal: SIMD3<Float>(0, 0, 1),
                params: params
            )
            #expect(abs(out.position.z) < 1e-6, "x = \(x)")
        }
    }

    @Test func sagIsZeroAtSpineAndFreeEdge() {
        // The parabolic bell pins both page edges.
        let d: Float = 0.0
        let r: Float = 0.05
        var params = CurlParams(d: d, r: r, psi: 0)
        let plainEdge = CurlFunction.deform(
            position: SIMD3<Float>(PageMesh.width, 0.1, 0), normal: SIMD3<Float>(0, 0, 1), params: params)
        params.sag = 0.02
        let saggedEdge = CurlFunction.deform(
            position: SIMD3<Float>(PageMesh.width, 0.1, 0), normal: SIMD3<Float>(0, 0, 1), params: params)
        #expect(abs(plainEdge.position.z - saggedEdge.position.z) < 1e-6)
    }
}

struct PageContentSourceTests {
    @Test func debugSourceOccupancyIsDeterministicAndVaried() {
        let source = DebugPageContentSource()
        #expect(source.sheetCount == 10)
        for sheet in 0..<10 {
            let front = source.occupiedSlots(sheet: sheet, side: .front)
            #expect(front.nonzeroBitCount == (sheet * 3) % 10)
            // Masks are contiguous from slot 0 and fit in 9 bits.
            #expect(front < (1 << 9) || front == 0x1FF)
            #expect(source.occupiedSlots(sheet: sheet, side: .front) == front)
        }
        // Both sides contribute to the sheet's mass.
        let source2 = DebugPageContentSource()
        let sheet5 = source2.occupiedCount(sheet: 5)
        #expect(sheet5 == (5 * 3) % 10 + (5 * 7 + 4) % 10)
    }

    @Test func outOfRangeSheetsAreEmpty() {
        let source = DebugPageContentSource()
        #expect(source.occupiedSlots(sheet: -1, side: .front) == 0)
        #expect(source.occupiedSlots(sheet: 10, side: .back) == 0)
        #expect(source.occupiedCount(sheet: 99) == 0)
    }
}

struct SleeveGeometryTests {
    @Test func pocketsStayWithinThePageWithRealisticMargins() {
        #expect(SleeveGeometry.marginX > 0.005)
        #expect(SleeveGeometry.marginY > 0.005)
        for slot in 0..<9 {
            let origin = SleeveGeometry.pocketOrigin(slot: slot)
            #expect(origin.x >= 0 && origin.x + SleeveGeometry.pocketWidth <= PageMesh.width)
            #expect(origin.y >= 0 && origin.y + SleeveGeometry.pocketHeight <= PageMesh.height)
        }
        // Slot 0 is top-left; slot 8 bottom-right.
        let first = SleeveGeometry.pocketOrigin(slot: 0)
        let last = SleeveGeometry.pocketOrigin(slot: 8)
        #expect(first.x < last.x)
        #expect(first.y > last.y)
    }

    @Test func gridCountsAreConsistent() {
        let positions = SleeveGeometry.positions(zOffset: SleeveGeometry.surfaceOffset)
        #expect(positions.count == SleeveGeometry.vertexCountPerSide)
        #expect(SleeveGeometry.uvs().count == positions.count)
        let indices = SleeveGeometry.indices(front: true)
        #expect(indices.count == SleeveGeometry.indexCountPerSide)
        #expect(indices.allSatisfy { $0 < UInt32(positions.count) })
        // Back side reverses winding (same index multiset per triangle).
        let back = SleeveGeometry.indices(front: false)
        #expect(back.count == indices.count)
        #expect(back[1] == indices[2] && back[2] == indices[1])
        // All pocket film floats off the page plane.
        #expect(positions.allSatisfy { $0.z == SleeveGeometry.surfaceOffset })
    }
}
