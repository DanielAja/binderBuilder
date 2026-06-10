//
//  BrowseView.swift
//  binderBuilder
//
//  The Browse tab: switch between full-text card search and set browsing.
//  (Phase 3 adds filters/sort + per-set completion bars.)
//

import SwiftUI

struct BrowseView: View {
    let env: AppEnvironment
    @State private var mode: Mode = .search

    enum Mode: String, CaseIterable { case search = "Search", sets = "Sets" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])

                switch mode {
                case .search: SearchView(env: env)
                case .sets: SetBrowserView(env: env)
                }
            }
            .navigationTitle("Browse")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
