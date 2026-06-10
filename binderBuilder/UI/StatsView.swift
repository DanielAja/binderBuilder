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

    var body: some View {
        List {
            Section("Overview") {
                row("Collection value", stats.totalValue.formatted(.currency(code: "USD")))
                row("Cards", "\(stats.totalCopies)")
                row("Unique printings", "\(stats.distinctPrintings)")
                row("Sets started", "\(stats.setsStarted)")
                row("Sets completed", "\(stats.setsCompleted)")
            }

            if !stats.rarityCounts.isEmpty {
                Section("By Rarity") { breakdown(stats.rarityCounts) }
            }
            if !stats.typeCounts.isEmpty {
                Section("By Type") { breakdown(stats.typeCounts) }
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
        .task { await stats.refreshIfNeeded() }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary).monospacedDigit() }
    }

    @ViewBuilder
    private func breakdown(_ counts: [String: Int]) -> some View {
        let sorted = counts.sorted { $0.value > $1.value }
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
            }
        }
    }
}
