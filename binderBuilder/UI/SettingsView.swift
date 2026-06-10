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
