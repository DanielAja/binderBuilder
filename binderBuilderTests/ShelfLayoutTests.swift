//
//  ShelfLayoutTests.swift
//  binderBuilderTests
//
//  Pure shelf-row geometry: face-out vs book-row binder placement and the
//  display-case positions.
//

import Testing
@testable import binderBuilder

struct ShelfLayoutTests {
    @Test func upToFourBindersStandFaceOutCentered() {
        for count in 1...4 {
            let placements = ShelfLayout.binderPlacements(count: count, openIndex: nil)
            #expect(placements.count == count)
            #expect(placements.allSatisfy { $0.faceOut })
            #expect(placements.allSatisfy { $0.lean == 0 })
            // Centered: the row's midpoint sits at x = 0.
            let mid = (placements.first!.x + placements.last!.x) / 2
            #expect(abs(mid) < 0.001)
            // Everything fits on the slab.
            #expect(placements.allSatisfy { abs($0.x) < ShelfLayout.rowWidth / 2 })
        }
    }

    @Test func aSingleBinderStandsInTheMiddle() {
        let placements = ShelfLayout.binderPlacements(count: 1, openIndex: 0)
        #expect(placements == [ShelfLayout.BinderPlacement(x: 0, faceOut: true, lean: 0)])
    }

    @Test func crowdedShelfFeaturesTheOpenBinderAndShelvesTheRestAsBooks() {
        let placements = ShelfLayout.binderPlacements(count: 7, openIndex: 3)
        #expect(placements.count == 7)
        #expect(placements[3].faceOut)
        let books = placements.enumerated().filter { $0.offset != 3 }.map(\.element)
        #expect(books.allSatisfy { !$0.faceOut })
        // The featured binder stands left of the book row.
        #expect(books.allSatisfy { $0.x > placements[3].x })
        // Books march rightward in order.
        #expect(books == books.sorted { $0.x < $1.x })
        // Only the last book leans, and only when there's slack.
        #expect(books.dropLast().allSatisfy { $0.lean == 0 })
        #expect(books.last?.lean == ShelfLayout.bookLean)
    }

    @Test func unknownOpenBinderFeaturesTheFirst() {
        let placements = ShelfLayout.binderPlacements(count: 6, openIndex: nil)
        #expect(placements[0].faceOut)
        #expect(placements.dropFirst().allSatisfy { !$0.faceOut })
    }

    @Test func displayPositionsKeepTheClassicThreeCaseSpacing() {
        #expect(ShelfLayout.displayXs(count: 3) == [-0.34, 0, 0.34])
        let five = ShelfLayout.displayXs(count: 5)
        #expect(five.count == 5)
        #expect(abs(five[2]) < 0.001)                       // centered
        #expect(five.last! <= 0.49)                         // on the slab
        let spacing = five[1] - five[0]
        #expect(five.dropFirst().enumerated().allSatisfy { index, x in
            abs(x - five[index] - spacing) < 0.0001         // even spacing
        })
    }

    @Test func addPedestalJoinsTheRowAndStaysOnTheSlab() {
        for count in 3..<5 {
            let cases = ShelfLayout.displayXs(count: count, reserveAddSlot: true)
            let pedestal = ShelfLayout.addSlotX(count: count, maxCount: 5)
            #expect(cases.count == count)
            #expect(pedestal != nil)
            #expect(pedestal! > cases.last!)
            #expect(pedestal! <= 0.49)                      // on the slab
            // The whole row (cases + pedestal) is centered.
            #expect(abs(cases.first! + pedestal!) < 0.001)
        }
        #expect(ShelfLayout.addSlotX(count: 5, maxCount: 5) == nil)
        // At capacity the cases reclaim the full row.
        #expect(ShelfLayout.displayXs(count: 5, reserveAddSlot: false).count == 5)
    }
}
