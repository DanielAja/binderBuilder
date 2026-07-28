//
//  HomeView.swift
//  binderBuilder
//
//  Collection dashboard: portfolio value + trend, headline stats, quick
//  actions, a tap-to-replay "Recent Pulls" strip, sets in progress
//  (completion rings), and most-valuable cards. Powered by
//  CollectionStatsStore (cached aggregates).
//

import SwiftUI

struct HomeView: View {
    let env: AppEnvironment
    @Binding var selectedTab: RootTab
    @State private var showingScan = false
    @State private var showingFastScan = DebugLaunchState.launchFlag("-showFastScan")
    @State private var showingTrade = DebugLaunchState.launchFlag("-showTrade")
    @State private var showingTradeEditor = DebugLaunchState.launchFlag("-tradeEditorDemo")
    @State private var showingRecentPullsReplay = false
    @State private var shownValue = 0.0
    @ScaledMetric(relativeTo: .largeTitle) private var valueFontSize: CGFloat = 40
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var stats: CollectionStatsStore { env.stats }

    private func animateValue() {
        if reduceMotion { shownValue = stats.totalValue }
        else { withAnimation(.easeOut(duration: 0.7)) { shownValue = stats.totalValue } }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    valueCard
                    statTiles
                    quickActions
                    if !stats.recent.isEmpty { recentPulls }
                    if !stats.setProgress.isEmpty { setsInProgress }
                    if !stats.topValuable.isEmpty { mostValuable }
                }
                .padding()
            }
            .navigationTitle("My Collection")
            .navigationDestination(for: CardSummary.self) { CardDetailView(card: $0, env: env) }
            .navigationDestination(for: SetInfo.self) { SetCardsView(set: $0, env: env) }
            .sheet(isPresented: $showingScan) { ScanView(env: env) }
            .fullScreenCover(isPresented: $showingFastScan) { FastScanView(env: env) }
            .sheet(isPresented: $showingTrade) { ConventionView(env: env) }
            .sheet(isPresented: $showingTradeEditor) { TradeEditorView(env: env, existing: TradeEditorView.demoTrade) }
            .fullScreenCover(isPresented: $showingRecentPullsReplay) {
                RevealView(items: recentPullItems) { showingRecentPullsReplay = false }
            }
            .task {
                await stats.refreshIfNeeded()
                animateValue()
                // So a recently-added card gets its one-time float glint the
                // first time it's pulled in the 3D binder (CardFloatSystem /
                // MotionUpdateSystem) — see RecentAdditions for the full story.
                for item in stats.recent { RecentAdditions.shared.mark(cardID: item.card.id) }
            }
            .onChange(of: stats.totalValue) { _, _ in animateValue() }
            .refreshable { await stats.refresh() }
        }
    }

    // MARK: Value

    private var valueCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Collection Value").font(.subheadline).foregroundStyle(.secondary)
            Text(shownValue, format: .currency(code: "USD"))
                .font(.system(size: valueFontSize, weight: .bold, design: .rounded))
                .contentTransition(.numericText(value: shownValue))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
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

    // MARK: Recent Pulls

    /// card.id -> value, from the already-computed most-valuable list — so the
    /// priciest card in the strip can get the shimmer treatment without a
    /// second price lookup.
    private var recentValueByCardID: [String: Double] {
        Dictionary(stats.topValuable.map { ($0.card.id, $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    private var mostValuableRecentID: String? {
        stats.recent.compactMap { item in recentValueByCardID[item.card.id].map { (item.card.id, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    private var recentPullItems: [RevealItem] {
        let values = recentValueByCardID
        return stats.recent.map { item in
            RevealItem(cardID: item.card.id, name: item.card.name,
                      imageBase: item.card.imageBase, price: values[item.card.id])
        }
    }

    /// A tappable replay strip of the most recent adds — one tap opens the
    /// full RevealView "pack reveal" theater over the whole strip. The
    /// priciest card in the strip gets a tiltShimmer sheen.
    private var recentPulls: some View {
        Section {
            Button {
                Haptics.selection()
                showingRecentPullsReplay = true
            } label: {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(stats.recent) { item in
                            Group {
                                if item.card.id == mostValuableRecentID {
                                    recentPullTile(item).tiltShimmer()
                                } else {
                                    recentPullTile(item)
                                }
                            }
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Recent pulls, tap to replay")
        } header: { sectionHeader("Recent Pulls") }
    }

    private func recentPullTile(_ item: RecentCopy) -> some View {
        CardImageView(cardID: item.card.id, imageBase: item.card.imageBase,
                      quality: .low, imageCache: env.imageCache)
            .frame(width: 64, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var quickActions: some View {
        VStack(spacing: 10) {
            Button { showingFastScan = true } label: {
                actionLabel("Fast Scan — Live Price", systemImage: "camera.viewfinder")
            }.buttonStyle(.borderedProminent)
            HStack(spacing: 10) {
                Button { showingTrade = true } label: {
                    actionLabel("Trade", systemImage: "arrow.left.arrow.right")
                }.buttonStyle(.bordered)
                Button { selectedTab = .binder } label: {
                    actionLabel("Binder", systemImage: "book.fill")
                }.buttonStyle(.bordered)
            }
            HStack(spacing: 10) {
                Button { showingScan = true } label: {
                    actionLabel("Scan Page", systemImage: "square.grid.3x3.fill")
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
    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 180

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
        .frame(width: cardWidth)
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
