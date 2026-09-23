//
//  ReviewFixTests.swift
//  binderBuilderTests
//
//  Locale-aware decimal entry, which copies an outgoing trade hands over,
//  when un-owning a card needs a confirmation, the for-trade toggle clearing
//  every listing, and the bounded export art.
//

import CoreGraphics
import Foundation
import Testing
@testable import binderBuilder

@Suite struct DecimalInputTests {
    @Test func acceptsEitherDecimalSeparator() {
        #expect(DecimalInput.parse("12.50") == 12.5)
        #expect(DecimalInput.parse("12,50") == 12.5)
        #expect(DecimalInput.parse(" 7 ") == 7)
        #expect(DecimalInput.parse("$12.50") == 12.5)
        #expect(DecimalInput.parse("0,5") == 0.5)
    }

    @Test func treatsRepeatedOrEarlierSeparatorsAsGrouping() {
        #expect(DecimalInput.parse("1,234.50") == 1234.5)
        #expect(DecimalInput.parse("1.234,50") == 1234.5)
        #expect(DecimalInput.parse("1.234.567") == 1_234_567)
        #expect(DecimalInput.parse("1 234,5") == 1234.5)
    }

    @Test func rejectsNonNumbers() {
        #expect(DecimalInput.parse("") == nil)
        #expect(DecimalInput.parse("abc") == nil)
        #expect(DecimalInput.parse("12,5,0x") == nil)
    }

    @Test func formatsForTheLocaleAndRoundTrips() {
        let german = DecimalInput.string(12.5, locale: Locale(identifier: "de_DE"))
        #expect(german == "12,5")
        #expect(DecimalInput.parse(german) == 12.5)
        #expect(DecimalInput.string(12.5, locale: Locale(identifier: "en_US")) == "12.5")
        #expect(DecimalInput.string(10, locale: Locale(identifier: "en_US")) == "10")
    }
}

@Suite struct TradeCopySelectionTests {
    let ref = CardRef(cardID: "base1-4", variant: .holo)

    private func copy(_ id: String, _ condition: CardCondition, graded: Bool = false, age: Double = 0) -> CardCopy {
        CardCopy(id: id, ref: ref, condition: condition,
                 grade: graded ? CardGrade(company: .psa, value: 10) : nil,
                 acquiredAt: Date(timeIntervalSince1970: 1_000_000 + age))
    }

    @Test func prefersTheTradedConditionOverTheWorstCopy() {
        let copies = [copy("dmg", .dmg), copy("nm", .nm), copy("lp", .lp)]
        let picked = CollectionStore.copiesToTrade(from: copies, condition: .nm, count: 1)
        #expect(picked.map(\.id) == ["nm"])
    }

    @Test func fallsBackToTheNearestConditionThenOldest() {
        let copies = [copy("dmg", .dmg), copy("mp-new", .mp, age: 50), copy("mp-old", .mp, age: 10), copy("nm", .nm)]
        let picked = CollectionStore.copiesToTrade(from: copies, condition: .lp, count: 3)
        // NM and MP are both one step from LP: all three are distance 1, oldest first.
        #expect(Set(picked.map(\.id)) == ["nm", "mp-old", "mp-new"])
        #expect(!picked.contains { $0.id == "dmg" })
    }

    @Test func gradedSlabsGoLast() {
        let copies = [copy("slab", .nm, graded: true), copy("raw-hp", .hp)]
        #expect(CollectionStore.copiesToTrade(from: copies, condition: .nm, count: 1).map(\.id) == ["raw-hp"])
        #expect(CollectionStore.copiesToTrade(from: copies, condition: .nm, count: 5).map(\.id) == ["raw-hp", "slab"])
        #expect(CollectionStore.copiesToTrade(from: copies, condition: .nm, count: 0).isEmpty)
    }

    @MainActor @Test func removeTradedCopiesKeepsTheOthers() throws {
        let store = CollectionStore(database: try UserDatabase.inMemory())
        store.addCopy(ref, condition: .dmg)
        let nm = try #require(store.addCopy(ref, condition: .nm))
        store.addCopy(ref, condition: .nm, grade: CardGrade(company: .psa, value: 9))
        store.removeTradedCopies(of: ref, condition: .nm, count: 1)
        let left = store.copies(of: ref)
        #expect(left.count == 2)
        #expect(!left.contains { $0.id == nm.id })
        #expect(left.contains { $0.condition == .dmg })
        #expect(left.contains { $0.isGraded })
    }
}

@Suite struct RemovalConfirmationTests {
    let ref = CardRef(cardID: "base1-4", variant: .holo)

    @Test func loneBareRawCopyNeedsNoConfirmation() {
        #expect(!CollectionStore.removalNeedsConfirmation([CardCopy(ref: ref)]))
        #expect(!CollectionStore.removalNeedsConfirmation([]))
    }

    @Test func anythingElseAsksFirst() {
        #expect(CollectionStore.removalNeedsConfirmation([CardCopy(ref: ref), CardCopy(ref: ref)]))
        #expect(CollectionStore.removalNeedsConfirmation([CardCopy(ref: ref, grade: CardGrade(company: .cgc, value: 9.5))]))
        #expect(CollectionStore.removalNeedsConfirmation([CardCopy(ref: ref, acquiredPrice: 40)]))
        #expect(CollectionStore.removalNeedsConfirmation([CardCopy(ref: ref, notes: "from Dad")]))
    }

    @Test func phraseNamesCountAndGraded() {
        #expect(CollectionStore.copiesPhrase([CardCopy(ref: ref)]) == "1 copy")
        #expect(CollectionStore.copiesPhrase([
            CardCopy(ref: ref), CardCopy(ref: ref), CardCopy(ref: ref, grade: CardGrade(company: .psa, value: 10)),
        ]) == "3 copies (1 graded)")
    }
}

@MainActor @Suite struct TradeListToggleTests {
    @Test func toggleOffRemovesEveryListingOfThePrinting() throws {
        let store = TradeListStore(database: try UserDatabase.inMemory())
        let ref = CardRef(cardID: "base1-4", variant: .holo)
        let other = CardRef(cardID: "base1-58", variant: .normal)
        store.save(TradeListing(ref: ref, condition: .nm))
        store.save(TradeListing(ref: ref, condition: .lp))
        store.save(TradeListing(ref: other))
        #expect(store.count == 3)

        #expect(store.toggle(ref) == false)
        #expect(!store.isListed(ref))
        #expect(store.isListed(other))
        #expect(store.count == 1)
    }
}

@Suite struct BinderExportArtTests {
    @Test func artIsShrunkToPocketSizeAndDecodes() throws {
        let context = try #require(CGContext(
            data: nil, width: 600, height: 825, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 825))
        let full = try #require(context.makeImage())

        let data = try #require(BinderExport.exportArt(from: full))
        let decoded = try #require(BinderExport.decodeArt(data))
        #expect(max(decoded.width, decoded.height) == BinderExport.artMaxPixelSize)
        #expect(abs(Double(decoded.width) / Double(decoded.height) - 600.0 / 825.0) < 0.01)
        // Far smaller than the ~2 MB of decoded pixels it replaces.
        #expect(data.count < 100_000)
    }
}
