//
//  SettingsView.swift
//  binderBuilder
//
//  eBay pricing opt-in (the user pastes their own free developer keys; stored
//  in the Keychain), plus attribution and the IP disclaimer.
//

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let env: AppEnvironment

    @State private var exporting = false
    @State private var exportDocument: BackupDocument?
    @State private var importing = false
    @State private var statusMessage: String?
    @State private var cloudRestored = false
    @State private var confirmRestore = false

    private var cloudStatusText: String? {
        switch env.cloud.status {
        case .idle: return nil
        case .syncing: return "Syncing…"
        case .synced(let date): return "Last synced \(date.formatted(date: .abbreviated, time: .shortened))"
        case .unavailable(let msg): return msg
        case .failed(let msg): return "Sync failed: \(msg)"
        }
    }

    var body: some View {
        @Bindable var settings = env.settings
        Form {
            Section {
                Toggle("Show eBay active listings", isOn: $settings.ebayEnabled)
                if settings.ebayEnabled {
                    SecureField("eBay App ID", text: credential(\.ebayAppID))
                    SecureField("eBay Cert ID", text: credential(\.ebayCertID))
                }
            } header: {
                Text("eBay pricing")
            } footer: {
                Text("Optional: paste your own free eBay developer keys for live active-listing prices. Sold prices always work via the zero-API \"View sold on eBay\" link on each card.")
            }

            Section("Collection") {
                LabeledContent("Cards owned", value: "\(env.collection.ownedCount)")
                LabeledContent("Binders", value: "\(env.binders.binders.count)")
            }

            Section {
                Toggle("Price-drop alerts", isOn: $settings.priceAlertsEnabled)
                Toggle("New release alerts", isOn: $settings.newReleaseAlertsEnabled)
                Button { Task { await env.runAlertChecks() } } label: {
                    Label("Check now", systemImage: "arrow.clockwise")
                }
            } header: {
                Text("Alerts")
            } footer: {
                Text("Free and on-device, checked when you open the app. Watch a card from its ••• menu → Set Price Alert.")
            }
            .onChange(of: settings.priceAlertsEnabled) { _, on in if on { Task { await NotificationService.requestAuthorization() } } }
            .onChange(of: settings.newReleaseAlertsEnabled) { _, on in if on { Task { await NotificationService.requestAuthorization() } } }

            Section {
                Button {
                    if let data = try? BackupService.export(env.userDatabase) {
                        exportDocument = BackupDocument(data: data); exporting = true
                    }
                } label: { Label("Export collection", systemImage: "square.and.arrow.up") }
                Button {
                    importing = true
                } label: { Label("Import collection…", systemImage: "square.and.arrow.down") }
            } header: {
                Text("Backup")
            } footer: {
                Text("Export a JSON backup of your collection, binders, and wishlist, or import one. Importing replaces your current data — relaunch the app afterward.")
            }

            Section {
                Toggle("iCloud Sync", isOn: $settings.icloudSyncEnabled)
                Button { Task { await env.cloud.push() } } label: {
                    Label("Back up to iCloud now", systemImage: "icloud.and.arrow.up")
                }
                Button(role: .destructive) { confirmRestore = true } label: {
                    Label("Restore from iCloud", systemImage: "icloud.and.arrow.down")
                }
                if let line = cloudStatusText {
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text("Backs up your whole collection to your private iCloud. Restore replaces local data — relaunch to load it.")
            }
            .onChange(of: settings.icloudSyncEnabled) { _, on in if on { Task { await env.cloud.push() } } }
            .confirmationDialog("Restore from iCloud?", isPresented: $confirmRestore, titleVisibility: .visible) {
                Button("Replace local data", role: .destructive) {
                    Task { if await env.cloud.restoreFromCloud() { cloudRestored = true } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This replaces everything on this device with your iCloud backup. This can't be undone.")
            }
            .alert("Restored from iCloud", isPresented: $cloudRestored) {
                Button("OK", role: .cancel) {}
            } message: { Text("Relaunch the app to load your synced collection.") }

            Section("About") {
                LabeledContent("Card data", value: "TCGdex (MIT)")
                Text("Card images are fetched on demand from the TCGdex CDN; no card art ships in the app.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Not affiliated with, endorsed, or sponsored by Nintendo, Game Freak, Creatures, or The Pokémon Company. Pokémon and card images are property of their respective owners.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .fileExporter(isPresented: $exporting, document: exportDocument,
                      contentType: .json, defaultFilename: "binderbuilder-backup") { _ in }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                try BackupService.restore(data, into: env.userDatabase)
                statusMessage = "Imported. Relaunch the app to see your collection."
            } catch {
                statusMessage = "Import failed: \(error.localizedDescription)"
            }
        }
        .alert("Backup", isPresented: Binding(get: { statusMessage != nil },
                                              set: { if !$0 { statusMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(statusMessage ?? "") }
    }

    private func credential(_ keyPath: ReferenceWritableKeyPath<SettingsStore, String?>) -> Binding<String> {
        Binding(
            get: { env.settings[keyPath: keyPath] ?? "" },
            set: { env.settings[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }
}

/// Wraps the JSON backup blob for `.fileExporter`.
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
