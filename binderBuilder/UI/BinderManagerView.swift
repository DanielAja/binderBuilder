//
//  BinderManagerView.swift
//  binderBuilder
//
//  Create, rename, sort, export, and delete binders, and a quick collection
//  summary. (The 3D scene renders the first binder; choosing which binder to
//  open in 3D is a later enhancement.)
//

import SwiftUI
import UniformTypeIdentifiers

struct BinderManagerView: View {
    let env: AppEnvironment

    /// A sort waiting on its confirmation dialog.
    private struct PendingSort: Identifiable {
        let binder: Binder
        let key: BinderSortKey
        var id: String { "\(binder.id)|\(key.rawValue)" }
    }

    @State private var showingCreate = false
    @State private var renaming: Binder?
    @State private var renameText = ""
    @State private var showingScan = false
    @State private var pendingDelete: Binder?
    @State private var pendingSort: PendingSort?
    /// True while a sort's database rewrite + 3D re-snapshot is in flight.
    @State private var sorting = false
    /// 0...1 while an export renders; nil when idle.
    @State private var exportProgress: Double?
    @State private var pdfDocument: BinderPDFDocument?
    @State private var exportingPDF = false
    @State private var pdfFilename = "binder"
    @State private var pngShare: BinderPNGShare?

    private var busy: Bool { sorting || exportProgress != nil }

    var body: some View {
        List {
            Section("Collection") {
                Label("\(env.collection.ownedCount) cards owned", systemImage: "checkmark.seal.fill")
                Button {
                    showingScan = true
                } label: {
                    Label("Scan a real page", systemImage: "camera.viewfinder")
                }
            }
            Section("Binders") {
                ForEach(env.binders.binders) { binder in
                    NavigationLink {
                        BinderDetailView(env: env, binderID: binder.id)
                    } label: {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(hex: binder.coverColor) ?? .accentColor)
                                .frame(width: 26, height: 34)
                            VStack(alignment: .leading) {
                                Text(binder.name)
                                Text("\(binder.pageCount) sheets · \(env.binders.occupiedCount(binderID: binder.id)) cards")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .contextMenu {
                        Button("Rename") { renaming = binder; renameText = binder.name }
                        Menu("Sort by") {
                            ForEach(BinderSortKey.allCases) { key in
                                Button(key.title) { pendingSort = PendingSort(binder: binder, key: key) }
                            }
                        }
                        Menu("Export") {
                            Button("PDF") { export(binder, as: .pdf) }
                            Button("PNG Images") { export(binder, as: .pngs) }
                            Button("JPEG Images") { export(binder, as: .jpegs) }
                        }
                        Button("Delete", role: .destructive) { pendingDelete = binder }
                    }
                    .accessibilityHint("Touch and hold for rename, sort, export, and delete")
                }
                .onDelete { offsets in
                    if let index = offsets.first { pendingDelete = env.binders.binders[index] }
                }
                .onMove { from, to in
                    var ordered = env.binders.binders.map(\.id)
                    ordered.move(fromOffsets: from, toOffset: to)
                    env.binders.reorderBinders(ordered)
                    Haptics.selection()
                }
            }
        }
        .disabled(busy)
        .overlay { busyOverlay }
        .confirmationDialog("Delete binder?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete \(pendingDelete?.name ?? "")", role: .destructive) {
                if let id = pendingDelete?.id { env.binders.deleteBinder(id) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes the binder and its card placements. Your owned cards stay in your collection.")
        }
        .confirmationDialog("Sort by \(pendingSort?.key.title ?? "")?",
                            isPresented: Binding(get: { pendingSort != nil },
                                                 set: { if !$0 { pendingSort = nil } }),
                            titleVisibility: .visible) {
            Button("Sort \(pendingSort?.binder.name ?? "")") {
                if let pending = pendingSort { runSort(pending) }
                pendingSort = nil
            }
            Button("Cancel", role: .cancel) { pendingSort = nil }
        } message: {
            Text("Every card is reordered and packed to the front, so the empty pockets end up at the back. This replaces the current arrangement.")
        }
        .navigationTitle("Binders")
        .toolbar {
            EditButton()
            Button { showingCreate = true } label: { Image(systemName: "plus") }
        }
        .sheet(isPresented: $showingScan) { ScanView(env: env) }
        .sheet(item: $pngShare) { share in ExportShareSheet(urls: share.urls) }
        .fileExporter(isPresented: $exportingPDF, document: pdfDocument,
                      contentType: .pdf, defaultFilename: pdfFilename) { _ in }
        .sheet(isPresented: $showingCreate) {
            CreateBinderSheet { name, colorHex, pageCount in
                _ = env.binders.createBinder(name: name, coverColor: colorHex, pageCount: pageCount)
                Haptics.success()
            }
            .presentationDetents([.medium])
        }
        .alert("Rename binder", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let binder = renaming { env.binders.renameBinder(binder.id, to: renameText) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    /// Covers the list while a sort or a (multi-second) export runs.
    @ViewBuilder private var busyOverlay: some View {
        if busy {
            ZStack {
                Color.black.opacity(0.25).ignoresSafeArea()
                VStack(spacing: 12) {
                    if let progress = exportProgress {
                        ProgressView(value: progress)
                            .frame(width: 180)
                        Text("Rendering pages…")
                    } else {
                        ProgressView()
                        Text("Sorting…")
                    }
                }
                .font(.subheadline)
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(exportProgress != nil ? "Rendering pages" : "Sorting binder")
        }
    }

    // MARK: - Actions

    private func runSort(_ pending: PendingSort) {
        sorting = true
        Task {
            defer { sorting = false }
            guard await env.binders.sort(binderID: pending.binder.id, by: pending.key) else {
                env.errors.show("Nothing to sort in \(pending.binder.name) yet.")
                return
            }
            Haptics.success()
            // sort() bumped the changeToken; the Binder tab's observer
            // re-snapshots in place, so the camera and spread survive.
            env.errors.show("Sorted \(pending.binder.name) by \(pending.key.title).", isError: false)
        }
    }

    private func export(_ binder: Binder, as format: BinderExportFormat) {
        exportProgress = 0
        Task {
            defer { exportProgress = nil }
            let job = await BinderExport.prepare(
                binder: binder, store: env.binders, cache: env.imageCache
            ) { exportProgress = $0 }

            guard !job.pages.isEmpty else {
                env.errors.show("\(binder.name) has no cards to export yet.")
                return
            }
            do {
                switch format {
                case .pdf:
                    pdfDocument = BinderPDFDocument(data: BinderExport.pdfData(job))
                    pdfFilename = BinderExport.fileStem(binder.name)
                    exportingPDF = true
                case .pngs, .jpegs:
                    pngShare = BinderPNGShare(urls: try BinderExport.writeImages(job, format: format))
                }
                Haptics.success()
            } catch {
                env.errors.show("Couldn't export \(binder.name): \(error.localizedDescription)")
            }
        }
    }
}

/// New-binder form: name, a curated cover swatch row, and a sheet count.
private struct CreateBinderSheet: View {
    let onCreate: (String, String, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var colorHex = "#1B6CA8"
    @State private var pageCount = 10

    /// Leather-adjacent cover colors that read well on the 3D shelf.
    private static let swatches = [
        "#1B6CA8", "#B23A2E", "#2E7D32", "#8E24AA",
        "#E8B23A", "#37474F", "#6D4C41", "#C2185B",
    ]

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Section("Cover") {
                    HStack(spacing: 10) {
                        ForEach(Self.swatches, id: \.self) { hex in
                            swatch(hex)
                        }
                    }
                }
                Section("Pages") {
                    Stepper("\(pageCount) sheets", value: $pageCount, in: 1...50)
                }
            }
            .navigationTitle("New Binder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(name.isEmpty ? "New Binder" : name, colorHex, pageCount)
                        dismiss()
                    }
                }
            }
        }
    }

    private func swatch(_ hex: String) -> some View {
        Button {
            colorHex = hex
            Haptics.selection()
        } label: {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(hex: hex) ?? .gray)
                .frame(width: 34, height: 44)
                .overlay {
                    if colorHex == hex {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.primary, lineWidth: 2.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cover color \(hex)")
        .accessibilityAddTraits(colorHex == hex ? [.isSelected] : [])
    }
}

extension Color {
    /// Parses "#RRGGBB" (with or without the leading #).
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = Int(s, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// "#RRGGBB" round-trip for the cover-color picker (nil when the color
    /// can't resolve to sRGB components).
    var hexString: String? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        func byte(_ component: CGFloat) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}
