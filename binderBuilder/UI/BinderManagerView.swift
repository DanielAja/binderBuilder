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
    @State private var newName = ""
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
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(hex: binder.coverColor) ?? .accentColor)
                            .frame(width: 26, height: 34)
                        VStack(alignment: .leading) {
                            Text(binder.name)
                            Text("\(binder.pageCount) sheets")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
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
                            Button("PNGs") { export(binder, as: .pngs) }
                        }
                        Button("Delete", role: .destructive) { pendingDelete = binder }
                    }
                    .accessibilityHint("Touch and hold for rename, sort, export, and delete")
                }
                .onDelete { offsets in
                    if let index = offsets.first { pendingDelete = env.binders.binders[index] }
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
            Button { newName = ""; showingCreate = true } label: { Image(systemName: "plus") }
        }
        .sheet(isPresented: $showingScan) { ScanView(env: env) }
        .sheet(item: $pngShare) { share in ExportShareSheet(urls: share.urls) }
        .fileExporter(isPresented: $exportingPDF, document: pdfDocument,
                      contentType: .pdf, defaultFilename: pdfFilename) { _ in }
        .alert("New binder", isPresented: $showingCreate) {
            TextField("Name", text: $newName)
            Button("Create") {
                _ = env.binders.createBinder(
                    name: newName.isEmpty ? "New Binder" : newName, coverColor: "#1B6CA8"
                )
            }
            Button("Cancel", role: .cancel) {}
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
                case .pngs:
                    pngShare = BinderPNGShare(urls: try BinderExport.writePNGs(job))
                }
                Haptics.success()
            } catch {
                env.errors.show("Couldn't export \(binder.name): \(error.localizedDescription)")
            }
        }
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
}
