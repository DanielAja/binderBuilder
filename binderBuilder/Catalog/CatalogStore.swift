//
//  CatalogStore.swift
//  binderBuilder
//
//  UI-facing search state over a CatalogReading. Debounces keystrokes by
//  200ms with a cancelling Task so only the latest query hits the database.
//

import Foundation
import Observation

@MainActor @Observable final class CatalogStore {
    /// nil when the app shipped/launched without a usable catalog.sqlite.
    let catalog: (any CatalogReading)?

    var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            scheduleSearch()
        }
    }
    private(set) var results: [CardSummary] = []
    private(set) var isSearching = false

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let resultLimit: Int

    init(catalog: (any CatalogReading)?,
         debounce: Duration = .milliseconds(200),
         resultLimit: Int = 50) {
        self.catalog = catalog
        self.debounce = debounce
        self.resultLimit = resultLimit
    }

    var isAvailable: Bool { catalog != nil }

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let catalog, !query.isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { [debounce, resultLimit] in
            do {
                try await Task.sleep(for: debounce)
                let found = try await catalog.searchCards(matching: query, limit: resultLimit)
                guard !Task.isCancelled else { return }
                self.results = found
                self.isSearching = false
            } catch {
                // Cancellation (superseded keystroke) or a query failure:
                // a newer task owns the UI state in the former case.
                guard !Task.isCancelled else { return }
                self.results = []
                self.isSearching = false
            }
        }
    }
}
