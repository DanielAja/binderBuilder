//
//  HomeView.swift
//  binderBuilder
//
//  Collection dashboard: portfolio value + trend, headline stats, sets in
//  progress (completion rings), most-valuable and recently-added cards, and
//  quick actions. Powered by CollectionStatsStore (cached aggregates).
//

import SwiftUI

struct HomeView: View {
    let env: AppEnvironment
    @Binding var selectedTab: RootTab
    @State private var showingScan = false
    @State private var shownValue = 0.0

    private var stats: CollectionStatsStore { env.stats }

    private func animateValue() { withAnimation(.easeOut(duration: 0.7)) { shownValue = stats.totalValue } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    valueCard
                    statTiles
                    if !stats.setProgress.isEmpty { setsInProgress }
                    if !stats.topValuable.isEmpty { mostValuable }
                    if !stats.recent.isEmpty { recentlyAdded }
                    quickActions
                }
                .padding()
            }
            .navigationTitle("My Collection")
            .navigationDestination(for: CardSummary.self) { CardDetailView(card: $0, env: env) }
            .navigationDestination(for: SetInfo.self) { SetCardsView(set: $0, env: env) }
            .sheet(isPresented: $showingScan) { ScanView(env: env) }
            .task { await stats.refreshIfNeeded(); animateValue() }
            .onChange(of: stats.totalValue) { _, _ in animateValue() }
            .refreshable { await stats.refresh() }
        }
    }

    // MARK: Value

    private var valueCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Collection Value").font(.subheadline).foregroundStyle(.secondary)
            Text(shownValue, format: .currency(code: "USD"))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .contentTransition(.numericText(value: shownValue))
            HStack(spacing: 12) {
                Text("Raw \(stats.rawValue.formatted(.currency(code: "USD")))")
                    .font(.caption).foregroundStyle(.secondary)
                if stats.gradedValue > 0 {
                    Label("Graded \(stats.gradedValue.formatted(.currency(code: "USD")))", systemImage: "seal.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if stats.trend.count > 1 {
                Sparkline(values: stats.trend)
                    .frame(height: 44)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            LinearGradient(colors: [Color.accentColor.opacity(0.28), Color.accentColor.opacity(0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: Stat tiles

    private var statTiles: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StatTile(title: "Cards", value: "\(stats.totalCopies)", systemImage: "rectangle.stack.fill")
            StatTile(title: "Unique", value: "\(stats.distinctPrintings)", systemImage: "square.grid.3x3.fill")
            StatTile(title: "Sets Started", value: "\(stats.setsStarted)", systemImage: "circle.lefthalf.filled")
            StatTile(title: "Sets Done", value: "\(stats.setsCompleted)", systemImage: "checkmark.seal.fill")
        }
    }

    // MARK: Sections

    private var setsInProgress: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(stats.setProgress.prefix(8)) { p in
                        NavigationLink(value: p.setInfo) { SetProgressCard(progress: p) }
                            .buttonStyle(.pressable)
                    }
                }
            }
        } header: { sectionHeader("Sets in Progress") }
    }

    private var mostValuable: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(stats.topValuable) { item in
                        NavigationLink(value: item.card) {
                            VStack(spacing: 4) {
                                CardImageView(cardID: item.card.id, imageBase: item.card.imageBase,
                                              quality: .low, imageCache: env.imageCache)
                                    .frame(width: 86, height: 120)
                                Text(item.value, format: .currency(code: "USD"))
                                    .font(.caption2.bold()).foregroundStyle(.green)
                            }
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
        } header: { sectionHeader("Most Valuable") }
    }

    private var recentlyAdded: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(stats.recent) { item in
                        NavigationLink(value: item.card) {
                            CardImageView(cardID: item.card.id, imageBase: item.card.imageBase,
                                          quality: .low, imageCache: env.imageCache)
                                .frame(width: 80, height: 112)
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
        } header: { sectionHeader("Recently Added") }
    }

    private var quickActions: some View {
        VStack(spacing: 10) {
            Button { selectedTab = .binder } label: {
                actionLabel("Open Binder", systemImage: "book.fill")
            }.buttonStyle(.borderedProminent)
            HStack(spacing: 10) {
                Button { showingScan = true } label: {
                    actionLabel("Scan", systemImage: "camera.viewfinder")
                }.buttonStyle(.bordered)
                Button { selectedTab = .browse } label: {
                    actionLabel("Browse", systemImage: "magnifyingglass")
                }.buttonStyle(.bordered)
            }
        }
        .padding(.top, 4)
    }

    private func actionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage).frame(maxWidth: .infinity).padding(.vertical, 6)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Components

private struct StatTile: View {
    let title: String, value: String, systemImage: String
    var body: some View {
        HStack {
            Image(systemName: systemImage).font(.title3).foregroundStyle(.tint).frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.title3.bold())
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct SetProgressCard: View {
    let progress: SetProgress
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(progress.setInfo.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            ProgressView(value: progress.fraction)
                .tint(progress.isComplete ? .green : .accentColor)
            HStack {
                Text("\(progress.owned)/\(progress.total)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(progress.fraction * 100))%").font(.caption.bold())
                    .foregroundStyle(progress.isComplete ? .green : .primary)
            }
        }
        .frame(width: 180)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Minimal value-trend sparkline.
struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geo in
            let lo = values.min() ?? 0, hi = values.max() ?? 1
            let range = max(hi - lo, 0.0001)
            Path { path in
                for (i, v) in values.enumerated() {
                    let x = values.count > 1 ? geo.size.width * CGFloat(i) / CGFloat(values.count - 1) : 0
                    let y = geo.size.height * (1 - CGFloat((v - lo) / range))
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}
