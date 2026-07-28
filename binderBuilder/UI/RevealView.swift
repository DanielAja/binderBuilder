//
//  RevealView.swift
//  binderBuilder
//
//  The payoff after a scanning run: the cards you just added come back one at
//  a time, face down, and turn over. Value sets the drama — a chase pull gets
//  a heavier burst, a longer hang, a doubled glint, and waits for your tap
//  instead of moving on by itself.
//
//  The card back is `PlaceholderArt.cardBack`, the same original artwork the
//  3D layer's texture cache falls back to (Resources/cardback.png is not
//  referenced anywhere in the app). Nothing here imitates a real pack: the
//  stage is a plain dark field, the particles are rounded rects and stars, and
//  the whole sequence is silent.
//
//  Reduce Motion swaps the flip for a 180 ms crossfade and drops the particles,
//  but keeps every hang, every haptic, and the tap gate exactly as they are —
//  the pacing is the point, the spinning isn't.
//

import SwiftUI

struct RevealView: View {
    let items: [RevealItem]
    var onDismiss: (() -> Void)?

    init(items: [RevealItem], onDismiss: (() -> Void)? = nil) {
        self.items = items
        self.onDismiss = onDismiss
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var tapGate = TapGate()

    @State private var current: RevealBeat?
    @State private var faceUp = false
    @State private var glint: Double = 0
    @State private var burstTrigger = 0
    @State private var awaitingTap = false
    @State private var showOutro = false
    /// Set by the close button so the driver stops at its next mark even if the
    /// presenter hasn't torn the view down yet.
    @State private var ended = false

    private var imageCache: ImageCache { RevealImageCache.shared }

    private var item: RevealItem? {
        guard let current, items.indices.contains(current.index) else { return nil }
        return items[current.index]
    }

    private var isChase: Bool { current?.tier == .chase }

    var body: some View {
        ZStack {
            stageBackground
            if showOutro {
                outro.transition(.scale(scale: 0.92).combined(with: .opacity))
            } else {
                revealStage
            }
        }
        .preferredColorScheme(.dark)
        .contentShape(Rectangle())
        .onTapGesture { if awaitingTap { tapGate.signal() } }
        .overlay(alignment: .topTrailing) { closeButton }
        .task { await run() }
        // A dismiss while a chase card is waiting would otherwise leave the
        // driver suspended on the gate forever.
        .onDisappear { tapGate.signal() }
    }

    // MARK: - Stage

    private var stageBackground: some View {
        ZStack {
            RadialGradient(
                colors: [Color(white: 0.13), .black],
                center: .center, startRadius: 40, endRadius: 520)
            // Chase pulls push everything else back so the card is the only
            // thing left lit.
            Color.black.opacity(isChase && !showOutro ? 0.35 : 0)
                .animation(.easeInOut(duration: 0.3), value: isChase)
        }
        .ignoresSafeArea()
    }

    private var revealStage: some View {
        VStack(spacing: 0) {
            progressCaption
            Spacer(minLength: 12)
            cardStage
            Spacer(minLength: 12)
            caption
        }
        .padding(.vertical, 32)
    }

    @ViewBuilder
    private var progressCaption: some View {
        if let current, items.count > 1 {
            Text("\(current.index + 1) of \(items.count)")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
                .accessibilityHidden(true)
        }
    }

    private var cardStage: some View {
        ZStack {
            if !reduceMotion, let current {
                ParticleBurst(
                    trigger: burstTrigger,
                    intensity: RevealChoreography.burstIntensity(for: current.tier),
                    tint: current.tier == .chase ? Color(red: 0.98, green: 0.82, blue: 0.42) : .white)
            }
            cardFaces
        }
        .frame(maxWidth: 320)
        .padding(.horizontal, 28)
    }

    private var cardFaces: some View {
        ZStack {
            cardBack
                .rotation3DEffect(.degrees(turnAngle(back: true)), axis: (x: 0, y: 1, z: 0),
                                  perspective: 0.55)
                .animation(turnAnimation, value: faceUp)
                .opacity(faceUp ? 0 : 1)
                .animation(swapAnimation, value: faceUp)

            cardFront
                .rotation3DEffect(.degrees(turnAngle(back: false)), axis: (x: 0, y: 1, z: 0),
                                  perspective: 0.55)
                .animation(turnAnimation, value: faceUp)
                .opacity(faceUp ? 1 : 0)
                .animation(swapAnimation, value: faceUp)
        }
        .aspectRatio(63.0 / 88.0, contentMode: .fit)
        .shadow(color: .black.opacity(0.6), radius: 24, y: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cardAccessibilityLabel)
    }

    private var cardBack: some View {
        Image(decorative: PlaceholderArt.cardBack, scale: 1)
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var cardFront: some View {
        if let item {
            CardImageView(cardID: item.cardID, imageBase: item.imageBase,
                          quality: .high, imageCache: imageCache)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .glintSweep(progress: glint)
                .tiltShimmer()
        }
    }

    @ViewBuilder
    private var caption: some View {
        VStack(spacing: 6) {
            if let item, faceUp {
                Text(item.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let price = item.price {
                    Text(price, format: .currency(code: "USD"))
                        .font(.title2.bold().monospacedDigit())
                        .foregroundStyle(isChase ? Color(red: 0.98, green: 0.82, blue: 0.42) : .green)
                }
            }
            Text("Tap to continue")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
                .opacity(awaitingTap ? 1 : 0)
                .accessibilityHidden(!awaitingTap)
        }
        .frame(height: 92, alignment: .top)
        .animation(.easeInOut(duration: 0.2), value: awaitingTap)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
    }

    private var cardAccessibilityLabel: String {
        guard let item else { return "Revealing card" }
        guard faceUp else { return "Card face down" }
        guard let price = item.price else { return item.name }
        return "\(item.name), \(price.formatted(.currency(code: "USD")))"
    }

    // MARK: - Outro

    private var outro: some View {
        VStack(spacing: 20) {
            Text(summaryLine)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)

            if let best = bestPull {
                VStack(spacing: 10) {
                    Text("Best pull").font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    CardImageView(cardID: best.cardID, imageBase: best.imageBase,
                                  quality: .high, imageCache: imageCache)
                        .frame(maxWidth: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .tiltShimmer()
                        .shadow(color: .black.opacity(0.6), radius: 20, y: 10)
                    Text(best.name).font(.headline).foregroundStyle(.white).lineLimit(1)
                    if let price = best.price {
                        Text(price, format: .currency(code: "USD"))
                            .font(.title3.bold().monospacedDigit())
                            .foregroundStyle(Color(red: 0.98, green: 0.82, blue: 0.42))
                    }
                }
            }

            Button("Done") { finish() }
                .font(.headline)
                .padding(.horizontal, 28).padding(.vertical, 12)
                .floatingGlass()
                .foregroundStyle(.white)
        }
        .padding(32)
    }

    private var summaryLine: String {
        let value = items.compactMap(\.price).reduce(0, +)
        let cards = items.count == 1 ? "1 card" : "\(items.count) cards"
        return "\(cards) · \(value.formatted(.currency(code: "USD"))) added"
    }

    private var bestPull: RevealItem? {
        items.max { ($0.price ?? 0) < ($1.price ?? 0) }
    }

    private var closeButton: some View {
        Button { finish() } label: {
            Image(systemName: "xmark")
                .font(.headline)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .foregroundStyle(.white)
        .padding()
        .accessibilityLabel("Close reveal")
    }

    // MARK: - Animation shape

    private var turnAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: durationSeconds(RevealChoreography.crossfade))
            : .spring(response: durationSeconds(RevealChoreography.flip), dampingFraction: 0.8)
    }

    /// The face/back hand off at the halfway point of the turn rather than
    /// dissolving through it — under Reduce Motion it *is* the crossfade.
    private var swapAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: durationSeconds(RevealChoreography.crossfade))
            : .linear(duration: 0.001).delay(durationSeconds(RevealChoreography.flip) / 2)
    }

    private func turnAngle(back: Bool) -> Double {
        guard !reduceMotion else { return 0 }
        if back { return faceUp ? 180 : 0 }
        return faceUp ? 0 : -180
    }

    private func durationSeconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }

    // MARK: - Driver

    /// One task walks the whole batch. Every wait is a `Task.sleep` (or the tap
    /// gate), so cancelling the task on dismiss unwinds the run immediately.
    private func run() async {
        let marks = RevealChoreography.timeline(for: items, reduceMotion: reduceMotion)
        guard !marks.isEmpty else {
            showOutro = true
            return
        }

        for beat in marks {
            // Lay the next card down face-up-never: no animation, so the turn
            // that follows starts from a settled back.
            var settle = Transaction()
            settle.disablesAnimations = true
            withTransaction(settle) {
                current = beat
                faceUp = false
                glint = 0
            }
            // The lead-in gap doubles as the frame boundary that lets the back
            // actually render before it turns.
            try? await Task.sleep(for: RevealChoreography.gap)
            if stopped { return }

            // The rip: haptic first, then the burst, in the same tick.
            rip(beat.tier)
            burstTrigger &+= 1
            withAnimation(turnAnimation) { faceUp = true }
            withAnimation(glintAnimation(for: beat)) { glint = 1 }

            let turn = reduceMotion ? RevealChoreography.crossfade : RevealChoreography.flip
            try? await Task.sleep(for: turn)
            if stopped { return }
            try? await Task.sleep(for: beat.hang)
            if stopped { return }

            if beat.requiresTap {
                awaitingTap = true
                await tapGate.wait()
                awaitingTap = false
                if stopped { return }
            }
        }

        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showOutro = true }
    }

    private var stopped: Bool { ended || Task.isCancelled }

    /// Glint sweeps once for common/notable and twice for a chase pull. Reduce
    /// Motion collapses the delay to zero (`glintStart == start`) and the sweep
    /// rides the crossfade.
    private func glintAnimation(for beat: RevealBeat) -> Animation {
        let delay = durationSeconds(beat.glintStart - beat.start)
        let duration = durationSeconds(RevealChoreography.glintDuration)
        return .easeOut(duration: duration)
            .delay(delay)
            .repeatCount(beat.tier == .chase ? 2 : 1, autoreverses: false)
    }

    /// Same value language as `LiveScanModel.hapticForPrice`, felt at the rip.
    private func rip(_ tier: RevealTier) {
        switch tier {
        case .common:
            Haptics.impact(.light)
        case .notable:
            Haptics.impact(.medium)
        case .chase:
            Haptics.impact(.heavy)
            Task { try? await Task.sleep(for: .milliseconds(90)); Haptics.impact(.rigid) }
        }
    }

    private func finish() {
        ended = true
        tapGate.signal()
        onDismiss?()
    }
}

/// One process-wide cache for the reveal — the contract init takes no
/// environment, and the on-disk store is shared with the app's cache anyway, so
/// art fetched by the scanner is already on hand.
private enum RevealImageCache {
    static let shared = ImageCache.standard()
}

/// Lets the beat driver `await` a tap without polling. Main-actor confined, so
/// a tap and a dismiss can never resume the same continuation twice.
@MainActor
private final class TapGate {
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { waiter = $0 }
    }

    func signal() {
        let pending = waiter
        waiter = nil
        pending?.resume()
    }
}
