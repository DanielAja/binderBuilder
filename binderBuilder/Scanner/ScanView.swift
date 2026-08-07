//
//  ScanView.swift
//  binderBuilder
//
//  Recreate a real binder page from a photo: import an image (photo library —
//  the simulator path, and the share-sheet path on device), run the scan
//  pipeline, review the nine per-slot matches (swap among the shortlist or mark
//  empty/unknown), then commit to a new binder and mark the cards owned.
//

import PhotosUI
import SwiftUI

struct ScanView: View {
    let env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var pickerItem: PhotosPickerItem?
    @State private var matcher: CardHashMatcher?
    @State private var results: [ScanSlotResult] = []
    @State private var names: [String: String] = [:]
    @State private var busy = false
    /// Where the scanned cards land: an existing binder, or (nil) a fresh
    /// "Scanned Page" binder — the original behavior stays the default.
    @State private var destinationID: String?

    var body: some View {
        NavigationStack {
            Group {
                if results.isEmpty {
                    importPrompt
                } else {
                    reviewGrid
                }
            }
            .navigationTitle("Scan a Page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if !results.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { commit() }.disabled(busy)
                    }
                }
            }
            .task { if matcher == nil, let c = env.catalog { matcher = await CardHashMatcher.load(from: c) } }
            .onChange(of: pickerItem) { _, item in Task { await runScan(item) } }
        }
    }

    private var importPrompt: some View {
        VStack(spacing: 20) {
            ContentUnavailableView(
                "Recreate a binder page",
                systemImage: "camera.viewfinder",
                description: Text("Take or choose a flat photo of one 3×3 binder page. We'll identify each card.")
            )
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("Choose a photo", systemImage: "photo.on.rectangle")
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(.tint, in: Capsule())
                    .foregroundStyle(.white)
            }
            .disabled(busy)
            if busy {
                ProgressView("Scanning…")
                    .accessibilityLabel("Scanning the page")
            }
        }
        .padding()
    }

    private var reviewGrid: some View {
        ScrollView {
            destinationRow
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                ForEach($results) { $slot in
                    SlotCell(slot: $slot, name: names[$slot.wrappedValue.chosen?.cardID ?? ""])
                }
            }
            .padding()
            Text("Tap a slot to change or clear its match.")
                .font(.caption).foregroundStyle(.secondary).padding(.bottom)
        }
    }

    /// Pick which binder the page saves into (default: a fresh one).
    @ViewBuilder
    private var destinationRow: some View {
        if !env.binders.binders.isEmpty {
            HStack {
                Text("Save to")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("New “Scanned Page” binder") { destinationID = nil }
                    Divider()
                    ForEach(env.binders.binders) { binder in
                        Button(binder.name) { destinationID = binder.id }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(destinationName)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
            .padding(.horizontal)
            .padding(.top, 10)
        }
    }

    private var destinationName: String {
        destinationID.flatMap { id in
            env.binders.binders.first(where: { $0.id == id })?.name
        } ?? "New binder"
    }

    // MARK: Actions

    private func runScan(_ item: PhotosPickerItem?) async {
        guard let item, let matcher else { return }
        busy = true
        defer { busy = false }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data)?.normalizedCGImage() else {
            env.errors.show("Couldn't read that photo. Try a different image.")
            return
        }
        results = await BinderScanPipeline.scan(page: image, matcher: matcher)
        await resolveNames()
    }

    private func resolveNames() async {
        let ids = Set(results.flatMap { $0.matches.map(\.cardID) })
        for id in ids where names[id] == nil {
            if let detail = try? await env.catalog?.card(id: id) { names[id] = detail.name }
        }
    }

    private func commit() {
        busy = true
        defer { busy = false; dismiss() }
        let chosen = results.compactMap { $0.chosen }
        guard !chosen.isEmpty else { return }

        if let binderID = destinationID,
           env.binders.binders.contains(where: { $0.id == binderID }) {
            // Existing binder: fill forward from the first empty pocket
            // (firstEmptySlot re-reads after each quiet write).
            var overflow = 0
            env.binders.commitBatch { binders in
                for slot in results {
                    guard let match = slot.chosen else { continue }
                    let ref = CardRef(cardID: match.cardID, variant: .normal)
                    if let empty = binders.firstEmptySlot(binderID: binderID) {
                        binders.assign(ref, to: empty)
                        env.collection.setOwned(ref, quantity: 1)
                    } else {
                        overflow += 1
                    }
                }
            }
            if overflow > 0 {
                env.errors.show("\(overflow) card\(overflow == 1 ? "" : "s") didn't fit — the binder is full.")
            }
            return
        }

        guard let binder = env.binders.createBinder(
            name: "Scanned Page", coverColor: "#2E7D32", pageCount: 1) else { return }
        env.binders.commitBatch { binders in
            for slot in results {
                guard let match = slot.chosen else { continue }
                let ref = CardRef(cardID: match.cardID, variant: .normal)
                binders.assign(ref, to: SlotLocation(
                    binderID: binder.id, pageIndex: 0, side: .front, slotIndex: slot.slotIndex
                ))
                env.collection.setOwned(ref, quantity: 1)
            }
        }
    }
}

/// One reviewed slot: the crop with its match overlaid; tap to pick from the
/// shortlist or clear.
private struct SlotCell: View {
    @Binding var slot: ScanSlotResult
    let name: String?

    var body: some View {
        Menu {
            ForEach(slot.matches, id: \.cardID) { match in
                Button {
                    slot.chosen = match
                } label: {
                    Text("\(match.cardID) · \(Int(match.confidence * 100))%")
                }
            }
            Divider()
            Button("Mark empty / unknown", role: .destructive) { slot.chosen = nil }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    if let crop = slot.crop {
                        Image(decorative: crop, scale: 1)
                            .resizable().scaledToFill()
                    } else {
                        Color(white: 0.15)
                    }
                }
                .frame(width: 90, height: 124)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottom) { confidenceBadge }

                Text(slot.chosen == nil ? "—" : (name ?? slot.chosen!.cardID))
                    .font(.caption2).lineLimit(1).foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var confidenceBadge: some View {
        if let match = slot.chosen {
            let pct = Int(match.confidence * 100)
            Text("\(pct)%")
                .font(.caption2.bold())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(pct >= 80 ? Color.green : (pct >= 60 ? .orange : .red), in: Capsule())
                .foregroundStyle(.white)
                .padding(4)
        } else if slot.isEmpty {
            Text("empty").font(.caption2)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(4)
        }
    }
}

extension UIImage {
    /// Bakes orientation into an up-oriented CGImage for consistent cropping.
    func normalizedCGImage() -> CGImage? {
        if imageOrientation == .up { return cgImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
        return image.cgImage
    }
}
