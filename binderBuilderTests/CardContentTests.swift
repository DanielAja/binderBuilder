//
//  CardContentTests.swift
//  binderBuilderTests
//
//  Card-on-page content seam: snapshot occupancy mapping, back-slot column
//  mirroring, and that the debug provider drives the same occupancy the flip
//  dynamics read.
//

import Testing
import simd
@testable import binderBuilder

@Suite struct CardContentTests {
    private func ref(_ id: String) -> CardRef { CardRef(cardID: id, variant: .holo) }

    @Test func occupiedMaskReflectsFilledSlots() {
        var snap = SheetCardSnapshot.empty
        snap.front[0] = CardSlotRender(ref: ref("a"), imageBase: nil, owned: true)
        snap.front[8] = CardSlotRender(ref: ref("b"), imageBase: nil, owned: false)
        #expect(snap.occupiedMask(.front) == (1 << 0 | 1 << 8))
        #expect(snap.occupiedMask(.back) == 0)
    }

    @Test func backSlotsMirrorColumns() {
        // Slot 0 (top-left as seen from the back) maps to page-local top-right.
        #expect(CardSlotGeometry.physicalSlot(slot: 0, side: .back) == 2)
        #expect(CardSlotGeometry.physicalSlot(slot: 2, side: .back) == 0)
        #expect(CardSlotGeometry.physicalSlot(slot: 4, side: .back) == 4) // center fixed
        #expect(CardSlotGeometry.physicalSlot(slot: 3, side: .back) == 5)
        // Front is identity.
        for slot in 0..<9 {
            #expect(CardSlotGeometry.physicalSlot(slot: slot, side: .front) == slot)
        }
    }

    @Test func cardZHasOppositeSignPerSide() {
        let front = CardSlotGeometry.center(slot: 4, side: .front)
        let back = CardSlotGeometry.center(slot: 4, side: .back)
        #expect(front.z > 0)
        #expect(back.z < 0)
        // Center pocket has the same x,y on both sides (column 1 mirrors to itself).
        #expect(abs(front.x - back.x) < 1e-6)
        #expect(abs(front.y - back.y) < 1e-6)
    }

    @Test func debugProviderDrivesOccupancy() {
        let source = DebugCardContentSource(sheetCount: 10)
        // In-range sheets carry cards; out-of-range are empty.
        #expect(source.occupiedCount(sheet: 5) > 0)
        #expect(source.occupiedCount(sheet: -1) == 0)
        #expect(source.occupiedCount(sheet: 99) == 0)
        // Occupancy derived from snapshot matches the PageContentSource mask.
        let snap = source.snapshot(sheet: 4)
        #expect(source.occupiedSlots(sheet: 4, side: .front) == snap.occupiedMask(.front))
        #expect(source.occupiedSlots(sheet: 4, side: .back) == snap.occupiedMask(.back))
    }
}
