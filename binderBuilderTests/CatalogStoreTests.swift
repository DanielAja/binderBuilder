//
//  CatalogStoreTests.swift
//  binderBuilderTests
//

import Foundation
import Testing
@testable import binderBuilder

@MainActor struct CatalogStoreTests {
    /// Polls until `condition` holds or ~2s elapse.
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func debouncedSearchDeliversResults() async throws {
        let store = CatalogStore(catalog: try TestCatalog.makeCatalog(), debounce: .milliseconds(10))
        store.searchText = "char"
        #expect(store.isSearching == true)
        try await waitUntil { !store.results.isEmpty }
        #expect(Set(store.results.map(\.name)) == ["Charizard", "Charmeleon", "Charmander"])
        #expect(store.isSearching == false)
    }

    @Test func newerKeystrokeSupersedesOlderQuery() async throws {
        let store = CatalogStore(catalog: try TestCatalog.makeCatalog(), debounce: .milliseconds(50))
        store.searchText = "char"
        store.searchText = "pikachu"  // cancels the pending "char" task
        try await waitUntil { !store.results.isEmpty }
        #expect(store.results.map(\.id) == ["base1-58"])
        #expect(store.isSearching == false)
    }

    @Test func clearingTheQueryClearsResultsImmediately() async throws {
        let store = CatalogStore(catalog: try TestCatalog.makeCatalog(), debounce: .milliseconds(10))
        store.searchText = "char"
        try await waitUntil { !store.results.isEmpty }
        store.searchText = ""
        #expect(store.results.isEmpty)
        #expect(store.isSearching == false)
    }

    @Test func missingCatalogYieldsNoResultsAndNoSpinner() async throws {
        let store = CatalogStore(catalog: nil, debounce: .milliseconds(10))
        #expect(store.isAvailable == false)
        store.searchText = "char"
        #expect(store.isSearching == false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.results.isEmpty)
    }
}
