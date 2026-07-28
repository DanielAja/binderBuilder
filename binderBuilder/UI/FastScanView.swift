//
//  FastScanView.swift
//  binderBuilder
//
//  The fast scanner: point at a card and it identifies it live, shows the
//  current trading price the instant it matches (skeleton → live), and adds it
//  to your collection or for-trade list in one tap. Camera on device; a photo
//  picker stands in on the Simulator / when the camera is unavailable. A sticky
//  destination + default condition make a bulk run zero-extra-taps per card.
//

import AVFoundation
import PhotosUI
import SwiftUI

struct FastScanView: View {
    let env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var model: LiveScanModel
    @State private var scanner = CameraScanner()
    @State private var pickerItem: PhotosPickerItem?
    @State private var cameraDenied = false

    private var useCamera: Bool { CameraScanner.hasCamera }

    init(env: AppEnvironment) {
        self.env = env
        _model = State(initialValue: LiveScanModel(env: env))
    }

    var body: some View {
        ZStack {
            background
            reticle
            VStack {
                topBar
                Spacer()
                if let locked = model.locked {
                    ResultCard(locked: locked, model: model, env: env)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    hintCard.padding(.bottom, 8)
                }
            }
            .padding(.top, 8)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .overlay(alignment: .top) { actionToast }
        .animation(.spring(duration: 0.3), value: model.locked)
        .task { await start() }
        .onChange(of: pickerItem) { _, item in Task { await scanPhoto(item) } }
        .onDisappear { scanner.stop() }
    }

    // MARK: - Layers

    @ViewBuilder
    private var background: some View {
        if useCamera {
            CameraPreview(session: scanner.session).ignoresSafeArea()
            Color.black.opacity(0.15).ignoresSafeArea()
        } else {
            LinearGradient(colors: [Color(white: 0.12), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }

    /// Outlines exactly the pixels we hash: the preview fills the screen with
    /// `.resizeAspectFill`, so the reticle is the screen projection of the
    /// analyzed crop. `ignoresSafeArea` puts this in the preview's coordinate
    /// space, which is what makes the two agree on every device aspect.
    private var reticle: some View {
        GeometryReader { geo in
            let rect = SingleCardScanner.visibleCropRect(frameSize: model.frameSize,
                                                         viewSize: geo.size)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(model.locked == nil ? Color.white.opacity(0.7) : Color.green,
                              lineWidth: 3)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .shadow(radius: 6)
                .animation(.easeInOut(duration: 0.2), value: model.locked != nil)
                .onChange(of: geo.size, initial: true) { model.previewSize = geo.size }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline).padding(10).background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Close scanner")

            Picker("Add to", selection: $model.destination) {
                ForEach(LiveScanModel.Destination.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            // Takes the width that's left (up to a cap) rather than a fixed
            // 220 pt, so neither segment truncates at 375 pt or larger text.
            .frame(maxWidth: 340)
            .layoutPriority(1)

            Spacer(minLength: 0)

            Menu {
                Picker("Condition", selection: $model.defaultCondition) {
                    ForEach(CardCondition.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            } label: {
                Text(model.defaultCondition.rawValue)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .padding(.horizontal)
        .overlay(alignment: .bottom) {
            if model.addedCount > 0 {
                Text("Added \(model.addedCount) · \(model.addedValue, format: .currency(code: "USD"))")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .offset(y: 26)
            }
        }
    }

    @ViewBuilder
    private var hintCard: some View {
        VStack(spacing: 10) {
            if !model.isReady {
                ProgressView().tint(.white)
                Text("Loading card index…").foregroundStyle(.white.opacity(0.8))
            } else if useCamera {
                if cameraDenied {
                    Label("Camera access is off. Enable it in Settings to scan live.",
                          systemImage: "camera.metering.none")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center).padding(.horizontal, 40)
                } else {
                    Label("Center a card in the frame", systemImage: "viewfinder")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.85))
                }
            } else {
                photoFallback
            }
        }
        .padding(.horizontal)
    }

    private var photoFallback: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.viewfinder").font(.largeTitle).foregroundStyle(.white.opacity(0.8))
            Text("Live camera scanning runs on device.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.75))
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("Scan from a photo", systemImage: "photo.on.rectangle")
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(.tint, in: Capsule()).foregroundStyle(.white)
            }
        }
    }

    @ViewBuilder
    private var actionToast: some View {
        if let text = model.lastActionText {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 60)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Actions

    private func start() async {
        await model.prepare()
        if DebugLaunchState.launchFlag("-fastScanDemo") {
            await model.injectDemo(cardID: "base1-4")
            return
        }
        guard useCamera else { return }
        // `onFrame` is a @MainActor callback delivered on the main queue (the
        // 180 ms throttle lives in CameraScanner), so the model can be touched
        // directly. Capture the model rather than `self` so the scanner's
        // closure doesn't retain this view's @State storage — which holds the
        // scanner itself.
        let scanModel = model
        scanner.onFrame = { frame in scanModel.ingestFrame(frame) }
        if CameraScanner.authorization == .denied || CameraScanner.authorization == .restricted {
            cameraDenied = true
        }
        scanner.requestAccessAndStart()
    }

    private func scanPhoto(_ item: PhotosPickerItem?) async {
        guard let item,
              let data = try? await item.loadTransferable(type: Data.self),
              let cg = UIImage(data: data)?.normalizedCGImage() else { return }
        await model.scanStill(cg)
    }
}

// MARK: - Result card

private struct ResultCard: View {
    let locked: LiveScanModel.Locked
    let model: LiveScanModel
    let env: AppEnvironment
    /// The one-tap add target grows with Dynamic Type, capped so the row still
    /// fits the card thumbnail and its details on a 375 pt screen.
    @ScaledMetric(relativeTo: .title) private var addSize: CGFloat = 36

    private var variants: [CardVariant] {
        let available = CardVariant.allCases.filter { locked.card.availableVariants.contains($0) }
        return available.isEmpty ? [.normal] : available
    }

    var body: some View {
        HStack(spacing: 14) {
            CardImageView(cardID: locked.card.id, imageBase: locked.card.imageBase,
                          quality: .low, imageCache: env.imageCache)
                .frame(width: 62, height: 86)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(locked.card.name).font(.headline).lineLimit(1)
                Text("\(locked.card.setName) · #\(locked.card.localNumber)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                priceChip
                if variants.count > 1 { variantPicker }
            }

            Spacer(minLength: 4)
            actions
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(alignment: .topTrailing) { confidenceBadge }
    }

    @ViewBuilder
    private var priceChip: some View {
        if locked.priceLoading {
            Capsule().fill(Color.secondary.opacity(0.25)).frame(width: 84, height: 20).shimmering()
        } else if let price = locked.price {
            HStack(spacing: 5) {
                Text(price.display).font(.title3.bold().monospacedDigit()).foregroundStyle(.green)
                Image(systemName: price.isLive ? "dot.radiowaves.up.forward" : "clock")
                    .font(.caption2).foregroundStyle(price.isLive ? .green : .secondary)
            }
            .accessibilityLabel("Trading price \(price.display), \(price.isLive ? "live" : "from snapshot")")
        } else {
            Text("No price yet").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var variantPicker: some View {
        Menu {
            ForEach(variants, id: \.self) { v in
                Button {
                    model.chooseVariant(v)
                } label: {
                    Label(v.displayName, systemImage: v == locked.variant ? "checkmark" : "")
                }
            }
        } label: {
            Text(locked.variant.displayName)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color(.tertiarySystemFill), in: Capsule())
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button { model.quickAdd() } label: {
                Image(systemName: locked.added ? "checkmark.circle.fill" : "plus.circle.fill")
                    .font(.system(size: min(addSize, 52)))
                    .foregroundStyle(locked.added ? .green : Color.accentColor)
                    .symbolEffect(.bounce, value: locked.added)
            }
            .disabled(locked.added)
            .accessibilityLabel(locked.added ? "Added" : "Add to \(model.destination.rawValue)")

            Button { model.addToWishlist() } label: {
                Image(systemName: "heart").font(.title3).foregroundStyle(.pink)
            }
            .accessibilityLabel("Add to wishlist")
        }
    }

    @ViewBuilder
    private var confidenceBadge: some View {
        let pct = Int(locked.confidence * 100)
        Text("\(pct)%")
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(pct >= 80 ? Color.green : (pct >= 65 ? .orange : .red), in: Capsule())
            .foregroundStyle(.white)
            .padding(8)
    }
}

// MARK: - Camera preview

/// Wraps an `AVCaptureVideoPreviewLayer` (device-only; blank on the Simulator).
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
