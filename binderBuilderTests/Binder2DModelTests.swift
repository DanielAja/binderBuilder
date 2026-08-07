//
//  Binder2DModelTests.swift
//  binderBuilderTests
//
//  The 2D editor's view model: page building, the pure drag-preview math and
//  its equivalence with the store's authoritative moveCard, and undo.
//

import Foundation
import GRDB
import Testing
@testable import binderBuilder

@MainActor struct Binder2DModelTests {
    struct World {
        let user: UserDatabase
        let binders: BinderStore
        let binder: Binder
        let model: Binder2DModel
    }

    func makeWorld(pageCount: Int = 2) throws -> World {
        let user = try UserDatabase.inMemory()
        let binders = BinderStore(database: user, catalog: try TestCatalog.makeCatalog()) { _ in true }
        let binder = try #require(binders.createBinder(name: "Grid", coverColor: "#1B6CA8", pageCount: pageCount))
        return World(user: user, binders: binders, binder: binder,
                     model: Binder2DModel(store: binders, binderID: binder.id))
    }

    private func place(_ world: World, _ ordinal: Int, _ ref: CardRef) {
        world.binders.assign(ref, to: BinderStore.slotLocation(atOrdinal: ordinal, binderID: world.binder.id))
    }

    private func loc(_ world: World, _ ordinal: Int) -> SlotLocation {
        BinderStore.slotLocation(atOrdinal: ordinal, binderID: world.binder.id)
    }

    private let a = CardRef(cardID: "base1-4", variant: .holo)
    private let b = CardRef(cardID: "base1-58", variant: .normal)

    // MARK: - Page building

    @Test func reloadBuildsOnePageModelPerSheetSide() async throws {
        let world = try makeWorld(pageCount: 2)
        place(world, 0, a)      // page 0 front, slot 0
        place(world, 9, b)      // page 0 back, slot 0
        place(world, 35, a)     // page 1 back, slot 8

        await world.model.reload()
        let pages = world.model.pages
        #expect(pages.count == 4)
        #expect(pages.map(\.id) == ["0-0", "0-1", "1-0", "1-1"])
        #expect(pages[0].slots[0]?.card.id == "base1-4")
        #expect(pages[1].slots[0]?.card.id == "base1-58")
        #expect(pages[3].slots[8]?.card.id == "base1-4")
        #expect(pages.flatMap(\.slots).compactMap { $0 }.count == 3)
        #expect(world.model.loadedToken == world.binders.changeToken)
    }

    @Test func reloadIfNeededSkipsWhenTheTokenHasNotMoved() async throws {
        let world = try makeWorld()
        await world.model.reload()
        let before = world.model.loadedToken
        await world.model.reloadIfNeeded()
        #expect(world.model.loadedToken == before)

        _ = world.binders.setSlot(a, at: loc(world, 0))
        await world.model.reloadIfNeeded()
        #expect(world.model.loadedToken == world.binders.changeToken)
        #expect(world.model.pages[0].slots[0] != nil)
    }

    // MARK: - Move preview (pure) and store equivalence

    @Test func previewMatchesTheStoreForAnInsertShiftRipple() async throws {
        let world = try makeWorld(pageCount: 1)
        place(world, 0, a)
        place(world, 1, b)
        place(world, 2, a)
        place(world, 10, b)
        await world.model.reload()

        let flat = Binder2DModel.flattened(world.model.pages)
        let preview = try #require(Binder2DModel.applyMovePreview(flat, from: 10, to: 0, mode: .insertShift))

        _ = try #require(world.binders.moveCard(from: loc(world, 10), to: loc(world, 0), mode: .insertShift))
        await world.model.reload()
        let committed = Binder2DModel.flattened(world.model.pages)

        #expect(preview.count == committed.count)
        for index in preview.indices {
            #expect(preview[index]?.card.id == committed[index]?.card.id)
            #expect(preview[index]?.variant == committed[index]?.variant)
        }
    }

    @Test func previewMatchesTheStoreForASwap() async throws {
        let world = try makeWorld(pageCount: 2)
        place(world, 3, a)
        place(world, 20, b)
        await world.model.reload()

        let flat = Binder2DModel.flattened(world.model.pages)
        let preview = try #require(Binder2DModel.applyMovePreview(flat, from: 3, to: 20, mode: .swap))

        _ = try #require(world.binders.moveCard(from: loc(world, 3), to: loc(world, 20), mode: .swap))
        await world.model.reload()
        let committed = Binder2DModel.flattened(world.model.pages)
        for index in preview.indices {
            #expect(preview[index]?.card.id == committed[index]?.card.id)
        }
    }

    @Test func previewRefusesExactlyWhenTheStoreWould() async throws {
        let world = try makeWorld(pageCount: 1)
        for ordinal in 0..<18 { place(world, ordinal, a) }
        await world.model.reload()
        let flat = Binder2DModel.flattened(world.model.pages)

        // Full binder, source behind target: both refuse.
        #expect(Binder2DModel.applyMovePreview(flat, from: 0, to: 1, mode: .insertShift) == nil)
        #expect(world.binders.moveCard(from: loc(world, 0), to: loc(world, 1), mode: .insertShift) == nil)

        // Empty source: both refuse.
        var gappy = flat
        gappy[5] = nil
        #expect(Binder2DModel.applyMovePreview(gappy, from: 5, to: 0, mode: .swap) == nil)
    }

    @Test func rechunkRoundTripsThePageStructure() async throws {
        let world = try makeWorld(pageCount: 2)
        place(world, 0, a)
        place(world, 21, b)
        await world.model.reload()

        let pages = world.model.pages
        let rebuilt = Binder2DModel.rechunk(Binder2DModel.flattened(pages), like: pages)
        #expect(rebuilt == pages)
    }

    // MARK: - Undo

    @Test func undoRestoresTheLayoutBeforeEachMutation() async throws {
        let world = try makeWorld(pageCount: 1)
        place(world, 0, a)
        await world.model.reload()

        #expect(world.model.fill(loc(world, 1), with: b))
        #expect(world.model.move(from: loc(world, 1), to: loc(world, 0), mode: .swap) != nil)
        #expect(world.model.canUndo)

        #expect(world.model.undo())     // back out the swap
        var layout = Dictionary(uniqueKeysWithValues: world.binders.assignments(binderID: world.binder.id)
            .map { (BinderStore.ordinal(of: $0.location), $0.ref) })
        #expect(layout[0] == a)
        #expect(layout[1] == b)

        #expect(world.model.undo())     // back out the fill
        layout = Dictionary(uniqueKeysWithValues: world.binders.assignments(binderID: world.binder.id)
            .map { (BinderStore.ordinal(of: $0.location), $0.ref) })
        #expect(layout == [0: a])
        #expect(!world.model.canUndo)
    }

    @Test func failedMutationsDoNotGrowTheUndoStack() async throws {
        let world = try makeWorld(pageCount: 1)
        await world.model.reload()
        // Moving from an empty pocket fails and must not leave a snapshot.
        #expect(world.model.move(from: loc(world, 0), to: loc(world, 1), mode: .swap) == nil)
        #expect(!world.model.canUndo)
    }

    @Test func pageOpsClearTheUndoStack() async throws {
        let world = try makeWorld(pageCount: 1)
        await world.model.reload()
        #expect(world.model.fill(loc(world, 0), with: a))
        #expect(world.model.canUndo)

        #expect(world.model.addPage())
        #expect(!world.model.canUndo)   // a snapshot can't restore a page count

        #expect(world.model.insertPage(at: 0))
        #expect(world.model.removePage(at: 0))
        #expect(world.model.binder?.pageCount == 2)
    }
}
