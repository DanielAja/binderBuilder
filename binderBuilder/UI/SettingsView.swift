//
//  SettingsView.swift
//  binderBuilder
//
//  eBay pricing opt-in (the user pastes their own free developer keys; stored
//  in the Keychain), plus attribution and the IP disclaimer.
//

import SwiftUI

struct SettingsView: View {
    let env: AppEnvironment

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

            Section("About") {
                LabeledContent("Card data", value: "TCGdex (MIT)")
                Text("Card images are fetched on demand from the TCGdex CDN; no card art ships in the app.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Not affiliated with, endorsed, or sponsored by Nintendo, Game Freak, Creatures, or The Pokémon Company. Pokémon and card images are property of their respective owners.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }

    private func credential(_ keyPath: ReferenceWritableKeyPath<SettingsStore, String?>) -> Binding<String> {
        Binding(
            get: { env.settings[keyPath: keyPath] ?? "" },
            set: { env.settings[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }
}
