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
    /// iCloud already holds a backup this device didn't write: ask restore vs
    /// replace instead of silently overwriting it.
    @State private var showingCloudConflict = false
    /// True while an export/import is in flight; disables the Backup buttons
    /// so a second tap can't overlap the first.
    @State private var backupBusy = false
    /// Debug/deep-link: -showDrops opens the Drops screen once this tab loads
    /// (RootTabView routes the initial tab for the same flag).
    @State private var showingDrops = DebugLaunchState.launchFlag("-showDrops")

    private var cloudStatusText: String? {
        switch env.cloud.status {
        case .idle: return nil
        case .syncing: return "Syncing…"
        case .synced(let date): return "Last synced \(date.formatted(date: .abbreviated, time: .shortened))"
        case .unavailable(let msg): return msg
        case .failed(let msg): return "Sync failed: \(msg)"
        case .conflict(let date):
            let when = date.map { " from \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
            return "iCloud has a backup\(when) this device hasn't synced — not overwritten."
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
                NavigationLink { BinderManagerView(env: env) } label: {
                    LabeledContent("Binders", value: "\(env.binders.binders.count)")
                }
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
                Toggle("Release-date reminders", isOn: $settings.dropAlertsEnabled)
                NavigationLink("Release calendar & stores") { DropsView(env: env) }
            } header: {
                Text("Drops")
            } footer: {
                Text("Drops are release-date reminders, not live stock alerts — no free app can see what is actually on a store's shelf. We remind you what is coming and where you saved stores to look.")
            }
            // Reconcile both ways: on schedules the reminders right away, off
            // cancels the ones already pending instead of leaving them to fire.
            .onChange(of: settings.dropAlertsEnabled) { _, on in
                Task {
                    if on { await NotificationService.requestAuthorization() }
                    await DropScheduler.reconcile(env: env)
                }
            }

            Section {
                if backupBusy {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
                Button {
                    backupBusy = true
                    Task {
                        defer { backupBusy = false }
                        if let data = try? BackupService.export(env.userDatabase) {
                            exportDocument = BackupDocument(data: data); exporting = true
                        }
                    }
                } label: { Label("Export collection", systemImage: "square.and.arrow.up") }
                    .disabled(backupBusy)
                Button {
                    importing = true
                } label: { Label("Import collection…", systemImage: "square.and.arrow.down") }
                    .disabled(backupBusy)
            } header: {
                Text("Backup")
            } footer: {
                Text("Export a JSON backup of your collection, binders, and wishlist, or import one. Importing replaces your current data.")
            }

            Section {
                Toggle("iCloud Sync", isOn: $settings.icloudSyncEnabled)
                Button { Task { await pushChecked() } } label: {
                    Label("Back up to iCloud now", systemImage: "icloud.and.arrow.up")
                }
                Button(role: .destructive) { confirmRestore = true } label: {
                    Label("Restore from iCloud", systemImage: "icloud.and.arrow.down")
                }
                if let line = cloudStatusText {
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
                if env.cloud.hasConflict {
                    Button("Choose which copy to keep…") { showingCloudConflict = true }
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text("Backs up your whole collection to your private iCloud. Restore replaces local data. An existing iCloud backup is never overwritten without asking.")
            }
            // Turning sync on checks iCloud first: if a backup is already there,
            // the push holds back and the user chooses restore vs replace.
            .onChange(of: settings.icloudSyncEnabled) { _, on in if on { Task { await pushChecked() } } }
            .confirmationDialog("Restore from iCloud?", isPresented: $confirmRestore, titleVisibility: .visible) {
                Button("Replace local data", role: .destructive) {
                    Task { await restoreFromCloud() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This replaces everything on this device with your iCloud backup. This can't be undone.")
            }
            .confirmationDialog("iCloud already has a backup", isPresented: $showingCloudConflict,
                                titleVisibility: .visible) {
                Button("Restore iCloud backup to this device", role: .destructive) {
                    Task { await restoreFromCloud() }
                }
                Button("Replace iCloud backup with this device", role: .destructive) {
                    Task { await env.cloud.push(force: true) }
                }
                Button("Decide later", role: .cancel) {}
            } message: {
                Text("It was saved from another device or an earlier install. Keep the iCloud copy (replacing what's on this device), or overwrite it with this device's collection. Either choice can't be undone.")
            }
            .alert("Restored from iCloud", isPresented: $cloudRestored) {
                Button("OK", role: .cancel) {}
            } message: { Text("Your synced collection is loaded.") }

            Section("About") {
                LabeledContent("Card data", value: "TCGdex (MIT)")
                Text("Card images are fetched on demand from the TCGdex CDN; no card art ships in the app.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Not affiliated with, endorsed, or sponsored by Nintendo, Game Freak, Creatures, or The Pokémon Company. Pokémon and card images are property of their respective owners.")
                    .font(.caption).foregroundStyle(.secondary)
                // Review Guideline 5.1.1(i) wants the policy reachable from
                // inside the app, not only from the store listing.
                Link("Privacy Policy", destination: URL(string: "https://ajadigital.co/privacy")!)
                Link("Support & Feedback", destination: URL(string: "https://ajadigital.co/feedback")!)
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showingDrops) { NavigationStack { DropsView(env: env) } }
        .fileExporter(isPresented: $exporting, document: exportDocument,
                      contentType: .json, defaultFilename: "binderbuilder-backup") { _ in }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            backupBusy = true
            Task {
                defer { backupBusy = false }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    // The read itself (which may have to download an iCloud
                    // Drive file) runs off-main; only the GRDB restore below
                    // has to stay on the main actor.
                    let data = try await Task.detached(priority: .userInitiated) {
                        try Data(contentsOf: url)
                    }.value
                    try BackupService.restore(data, into: env.userDatabase)
                    await env.reloadAllStores()
                    statusMessage = "Imported. Your collection is loaded."
                } catch {
                    statusMessage = "Import failed: \(error.localizedDescription)"
                }
            }
        }
        .alert("Backup", isPresented: Binding(get: { statusMessage != nil },
                                              set: { if !$0 { statusMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(statusMessage ?? "") }
    }

    /// A push that surfaces the "iCloud already has a backup" choice instead
    /// of silently overwriting it.
    private func pushChecked() async {
        await env.cloud.push()
        if env.cloud.hasConflict { showingCloudConflict = true }
    }

    /// Restores from iCloud, then reloads every store in place.
    private func restoreFromCloud() async {
        guard await env.cloud.restoreFromCloud() else { return }
        await env.reloadAllStores()
        cloudRestored = true
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
