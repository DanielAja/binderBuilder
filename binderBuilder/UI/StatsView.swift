//
//  StatsView.swift
//  binderBuilder
//
//  Collection insights: overview, rarity/type breakdowns, most valuable, and
//  per-set completion — all from CollectionStatsStore.
//

import SwiftUI

struct StatsView: View {
    let env: AppEnvironment
    private var stats: CollectionStatsStore { env.stats }

    // Derived, sorted rows for the rarity/type breakdowns, computed in
    // `recomputeBreakdowns()` rather than inline in the `@ViewBuilder` (which
    // re-sorted the dictionary on every render).
    @State private var rarityRows: [(key: String, value: Int)] = []
    @State private var typeRows: [(key: String, value: Int)] = []

    /// Static + pure so it's cheap to hoist out of the view builder.
    nonisolated static func sortedCounts(_ counts: [String: Int]) -> [(key: String, value: Int)] {
        counts.sorted { $0.value > $1.value }
    }

    private func recomputeBreakdowns() {
        rarityRows = Self.sortedCounts(stats.rarityCounts)
        typeRows = Self.sortedCounts(stats.typeCounts)
    }

    var body: some View {
        List {
            Section("Overview") {
                row("Collection value", stats.totalValue.formatted(.currency(code: "USD")))
                row("Cards", "\(stats.totalCopies)")
                row("Unique printings", "\(stats.distinctPrintings)")
                row("Sets started", "\(stats.setsStarted)")
                row("Sets completed", "\(stats.setsCompleted)")
            }

            if !rarityRows.isEmpty {
                Section("By Rarity") { breakdown(rarityRows) }
            }
            if !typeRows.isEmpty {
                Section("By Type") { breakdown(typeRows) }
            }

            if !stats.topValuable.isEmpty {
                Section("Most Valuable") {
                    ForEach(stats.topValuable) { item in
                        HStack {
                            Text(item.card.name).lineLimit(1)
                            Spacer()
                            Text(item.value, format: .currency(code: "USD"))
                                .foregroundStyle(.green).monospacedDigit()
                        }
                    }
                }
            }

            if !stats.setProgress.isEmpty {
                Section("Set Completion") {
                    ForEach(stats.setProgress) { p in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(p.setInfo.name).lineLimit(1)
                                Spacer()
                                Text("\(p.owned)/\(p.total)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            ProgressView(value: p.fraction).tint(p.isComplete ? .green : .accentColor)
                        }
                    }
                }
            }
        }
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await stats.refreshIfNeeded()
            recomputeBreakdowns()
        }
        .onChange(of: stats.rarityCounts) { recomputeBreakdowns() }
        .onChange(of: stats.typeCounts) { recomputeBreakdowns() }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary).monospacedDigit() }
    }

    @ViewBuilder
    private func breakdown(_ sorted: [(key: String, value: Int)]) -> some View {
        let maxCount = sorted.first?.value ?? 1
        ForEach(sorted, id: \.key) { entry in
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(entry.key).font(.subheadline).lineLimit(1)
                    Spacer()
                    Text("\(entry.value)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * CGFloat(entry.value) / CGFloat(maxCount))
                }
                .frame(height: 6)
                .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.key)
            .accessibilityValue("\(entry.value)")
        }
    }
}
