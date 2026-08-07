//
//  BinderExportTests.swift
//  binderBuilderTests
//
//  The pure half of the binder export: page/side chunking, trailing-empty
//  trimming, filenames, and the PDF page-count math — plus one end-to-end
//  render to prove a multi-page PDF really comes out the far side.
//

import CoreGraphics
import Foundation
import Testing
@testable import binderBuilder

struct BinderExportPureTests {

    private func slot(_ cardID: String, name: String = "Charizard") -> BinderExportSlot {
        BinderExportSlot(
            ref: CardRef(cardID: cardID, variant: .holo),
            name: name, localNumber: "4", setName: "Base Set",
            imageBase: "en/base/base1/4")
    }

    private func page(_ index: Int, _ side: PageSide, filled: Int) -> BinderExportPage {
        var slots = [BinderExportSlot?](repeating: nil, count: SpreadModel.slotsPerPage)
        for i in 0..<filled { slots[i] = slot("card-\(index)-\(side.rawValue)-\(i)") }
        return BinderExportPage(pageIndex: index, side: side, slots: slots)
    }

    // MARK: - Chunking

    @Test func trailingEmptySidesAreTrimmedButInteriorOnesAreKept() {
        let pages = [
            page(0, .front, filled: 4),
            page(0, .back, filled: 0),   // interior gap — kept
            page(1, .front, filled: 1),
            page(1, .back, filled: 0),   // trailing — dropped
            page(2, .front, filled: 0),
            page(2, .back, filled: 0),
        ]
        let printable = BinderExport.printablePages(pages)
        #expect(printable.count == 3)
        #expect(printable.map(\.pageIndex) == [0, 0, 1])
        #expect(printable.map(\.side) == [.front, .back, .front])
        #expect(printable[1].isEmpty)
    }

    @Test func anEmptyBinderPrintsNothing() {
        let pages = (0..<3).flatMap { [page($0, .front, filled: 0), page($0, .back, filled: 0)] }
        #expect(BinderExport.printablePages(pages).isEmpty)
        #expect(BinderExport.pdfPageCount(for: pages) == 0)
        #expect(BinderExport.printablePages([]).isEmpty)
    }

    @Test func pdfPageCountIsOnePerPrintableSide() {
        // A fully occupied 5-sheet binder: 10 sides, 10 PDF pages.
        let full = (0..<5).flatMap { [page($0, .front, filled: 9), page($0, .back, filled: 9)] }
        #expect(BinderExport.pdfPageCount(for: full) == 10)
        // One card on the last sheet's back still needs every page before it.
        var sparse = (0..<5).flatMap { [page($0, .front, filled: 0), page($0, .back, filled: 0)] }
        sparse[9] = page(4, .back, filled: 1)
        #expect(BinderExport.pdfPageCount(for: sparse) == 10)
    }

    // MARK: - Filenames

    @Test func fileStemIsSafeAndNeverEmpty() {
        #expect(BinderExport.fileStem("Chase & Grails!") == "Chase-Grails")
        #expect(BinderExport.fileStem("  spaced   out  ") == "spaced-out")
        #expect(BinderExport.fileStem("Binder/2026") == "Binder-2026")
        #expect(BinderExport.fileStem("") == "binder")
        #expect(BinderExport.fileStem("///") == "binder")
        #expect(BinderExport.fileStem(String(repeating: "a", count: 200)).count == 48)
    }

    @Test func pngFileNamesArePaddedAndSideLabelled() {
        #expect(BinderExport.pngFileName(binderName: "My Binder", page: page(0, .front, filled: 1))
                == "My-Binder-p01-front.png")
        #expect(BinderExport.pngFileName(binderName: "My Binder", page: page(11, .back, filled: 1))
                == "My-Binder-p12-back.png")
    }

    @Test func pageTitlesNameTheBinderPageAndSide() {
        #expect(BinderExport.pageTitle(binderName: "Grails", page: page(2, .back, filled: 0))
                == "Grails — Page 3 (back)")
        #expect(BinderExport.pageTitle(binderName: "Grails", page: page(0, .front, filled: 0))
                == "Grails — Page 1 (front)")
    }

    @Test func imageFileNamesCarryTheFormatExtension() {
        #expect(BinderExport.imageFileName(binderName: "My Binder", page: page(0, .front, filled: 1),
                                           fileExtension: "jpg")
                == "My-Binder-p01-front.jpg")
        #expect(BinderExportFormat.jpegs.fileExtension == "jpg")
        #expect(BinderExportFormat.pngs.fileExtension == "png")
        #expect(BinderExportFormat.pdf.fileExtension == "pdf")
    }

    // MARK: - Scopes

    @Test func scopesSelectExactlyTheAskedForSides() {
        let pages = (0..<3).flatMap { [page($0, .front, filled: $0 == 0 ? 2 : 0),
                                       page($0, .back, filled: 0)] }

        // .all trims trailing empties (existing behavior).
        #expect(BinderExport.scoped(pages, scope: .all).count == 1)

        // Explicit scopes keep deliberately empty sides.
        let side = BinderExport.scoped(pages, scope: .side(pageIndex: 1, side: .back))
        #expect(side.map(\.pageIndex) == [1])
        #expect(side.map(\.side) == [.back])

        let sheet = BinderExport.scoped(pages, scope: .sheet(pageIndex: 2))
        #expect(sheet.map(\.side) == [.front, .back])
        #expect(sheet.allSatisfy { $0.pageIndex == 2 })

        // A spread is the previous sheet's back + this sheet's front.
        let spread = BinderExport.scoped(pages, scope: .spread(spreadIndex: 1))
        #expect(spread.map(\.pageIndex) == [0, 1])
        #expect(spread.map(\.side) == [.back, .front])

        // Edge spreads have a single visible side.
        #expect(BinderExport.scoped(pages, scope: .spread(spreadIndex: 0)).map(\.side) == [.front])
        #expect(BinderExport.scoped(pages, scope: .spread(spreadIndex: 3)).map(\.side) == [.back])

        // Out-of-range scopes are empty, not crashes.
        #expect(BinderExport.scoped(pages, scope: .sheet(pageIndex: 9)).isEmpty)
    }
}

// MARK: - Page building + rendering

@MainActor struct BinderExportRenderTests {

    private func makeBinderStore() throws -> (UserDatabase, BinderStore) {
        let user = try UserDatabase.inMemory()
        let catalog = try TestCatalog.makeCatalog()
        let collection = CollectionStore(database: user)
        return (user, BinderStore(database: user, catalog: catalog) { collection.isOwned($0) })
    }

    @Test func pagesFollowTheBindersSheetsAndSides() async throws {
        let (_, binders) = try makeBinderStore()
        let binder = try #require(binders.createBinder(name: "Pages", coverColor: "#1B6CA8", pageCount: 2))
        binders.assign(
            CardRef(cardID: "base1-4", variant: .holo),
            to: SlotLocation(binderID: binder.id, pageIndex: 0, side: .front, slotIndex: 0))
        binders.assign(
            CardRef(cardID: "swsh9-25", variant: .holo),
            to: SlotLocation(binderID: binder.id, pageIndex: 1, side: .back, slotIndex: 8))

        let pages = await BinderExport.pages(binderID: binder.id, store: binders)
        #expect(pages.count == 4)
        #expect(pages.map(\.pageIndex) == [0, 0, 1, 1])
        #expect(pages.map(\.side) == [.front, .back, .front, .back])
        #expect(pages[0].slots[0]?.name == "Charizard")
        #expect(pages[0].slots.compactMap { $0 }.count == 1)
        #expect(pages[1].isEmpty)
        #expect(pages[3].slots[8]?.name == "Lumineon V")
        // Nothing is trimmed until printablePages runs.
        #expect(BinderExport.printablePages(pages).count == 4)
    }

    @Test func anEmptyOrUnknownBinderHasNoPages() async throws {
        let (_, binders) = try makeBinderStore()
        #expect(await BinderExport.pages(binderID: "nope", store: binders).isEmpty)
        let zeroSheet = try #require(
            binders.createBinder(name: "Flat", coverColor: "#000000", pageCount: 0))
        #expect(await BinderExport.pages(binderID: zeroSheet.id, store: binders).isEmpty)
    }

    /// End to end without the network: the job carries no art, so every pocket
    /// renders as its titled placeholder — but the PDF still has one page per
    /// binder side.
    @Test func pdfHasOnePagePerPrintableSide() async throws {
        let (_, binders) = try makeBinderStore()
        let binder = try #require(binders.createBinder(name: "PDF", coverColor: "#1B6CA8", pageCount: 3))
        for slotIndex in 0..<4 {
            binders.assign(
                CardRef(cardID: "base1-4", variant: .holo),
                to: SlotLocation(binderID: binder.id, pageIndex: 1, side: .front, slotIndex: slotIndex))
        }

        let pages = BinderExport.printablePages(
            await BinderExport.pages(binderID: binder.id, store: binders))
        // Sheet 0 front + back, then sheet 1 front — sheet 2 is trimmed away.
        #expect(pages.count == 3)

        let job = BinderExportJob(binderName: binder.name, pages: pages, images: [:])
        let data = BinderExport.pdfData(job)
        let document = try #require(
            CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init))
        #expect(document.numberOfPages == 3)
        let box = try #require(document.page(at: 1)).getBoxRect(.mediaBox)
        #expect(box.size == BinderExport.pageSize)
    }

    @Test func pngsAreWrittenOnePerSideWithStableNames() async throws {
        let (_, binders) = try makeBinderStore()
        let binder = try #require(binders.createBinder(name: "Png Out", coverColor: "#1B6CA8", pageCount: 2))
        binders.assign(
            CardRef(cardID: "base1-58", variant: .normal),
            to: SlotLocation(binderID: binder.id, pageIndex: 0, side: .back, slotIndex: 2))

        let pages = BinderExport.printablePages(
            await BinderExport.pages(binderID: binder.id, store: binders))
        let job = BinderExportJob(binderName: binder.name, pages: pages, images: [:])
        let urls = try BinderExport.writePNGs(job)
        defer { urls.first.map { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } }

        #expect(urls.map(\.lastPathComponent) == ["Png-Out-p01-front.png", "Png-Out-p01-back.png"])
        for url in urls {
            #expect(FileManager.default.fileExists(atPath: url.path))
            let data = try Data(contentsOf: url)
            #expect(data.count > 0)
            // PNG magic number.
            #expect(Array(data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
        }
    }

    @Test func jpegsAreRealJpegsAndScopedExportsStayNarrow() async throws {
        let (_, binders) = try makeBinderStore()
        let binder = try #require(binders.createBinder(name: "Jpg Out", coverColor: "#1B6CA8", pageCount: 3))
        binders.assign(
            CardRef(cardID: "base1-4", variant: .holo),
            to: SlotLocation(binderID: binder.id, pageIndex: 1, side: .front, slotIndex: 0))

        // A single-side scope exports exactly one file even in a 3-sheet binder.
        let pages = BinderExport.scoped(
            await BinderExport.pages(binderID: binder.id, store: binders),
            scope: .side(pageIndex: 1, side: .front))
        #expect(pages.count == 1)

        let job = BinderExportJob(binderName: binder.name, pages: pages, images: [:])
        let urls = try BinderExport.writeImages(job, format: .jpegs)
        defer { urls.first.map { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } }

        #expect(urls.map(\.lastPathComponent) == ["Jpg-Out-p02-front.jpg"])
        let data = try Data(contentsOf: try #require(urls.first))
        // JPEG magic number.
        #expect(Array(data.prefix(3)) == [0xFF, 0xD8, 0xFF])
    }
}
