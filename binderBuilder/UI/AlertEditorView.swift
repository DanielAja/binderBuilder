//
//  AlertEditorView.swift
//  binderBuilder
//
//  Set or clear a price alert for one printing: notify when it drops below a
//  target price, or by a percentage from the current price.
//

import SwiftUI

struct AlertEditorView: View {
    let ref: CardRef
    let env: AppEnvironment
    let currentPrice: Double?

    @Environment(\.dismiss) private var dismiss
    @State private var kind: AlertKind = .belowTarget
    @State private var thresholdText = ""
    /// Header art only; nil until the catalog lookup lands (or forever, for a
    /// ref the catalog no longer knows).
    @State private var summary: CardSummary?
    @FocusState private var thresholdFieldFocused: Bool

    private var existing: PriceAlert? { env.alerts.alert(for: ref) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        CardImageView(cardID: ref.cardID, imageBase: summary?.imageBase,
                                      quality: .low, imageCache: env.imageCache)
                            .id(summary?.imageBase)
                            .frame(width: 44, height: 61)
                            .interactiveCard(card: summary, variant: ref.variant, intensity: 0.6)
                        Text(summary?.name ?? ref.fallbackName).font(.headline)
                    }
                }
                Section {
                    Picker("Alert when", selection: $kind) {
                        Text("Drops below price").tag(AlertKind.belowTarget)
                        Text("Drops by percent").tag(AlertKind.percentDrop)
                    }
                    HStack {
                        Text(kind == .belowTarget ? "Target price" : "Percent drop")
                        TextField(kind == .belowTarget ? "0.00" : "10", text: $thresholdText)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .focused($thresholdFieldFocused)
                    }
                } footer: {
                    if let currentPrice {
                        Text("Current price: \(currentPrice.formatted(.currency(code: "USD")))")
                    } else {
                        Text("Uses the free TCGdex market price, checked when you open the app.")
                    }
                }
                if existing != nil {
                    Section {
                        Button("Remove alert", role: .destructive) {
                            env.alerts.removeAlert(ref); dismiss()
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Price Alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!canSave) }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { thresholdFieldFocused = false }
                }
            }
            .onAppear {
                if let existing {
                    kind = existing.kind
                    thresholdText = String(existing.threshold)
                }
            }
            .task { summary = try? await env.catalog?.card(id: ref.cardID)?.summary }
        }
    }

    private var canSave: Bool { Double(thresholdText.trimmingCharacters(in: .whitespaces)) != nil }

    private func save() {
        guard let threshold = Double(thresholdText.trimmingCharacters(in: .whitespaces)) else { return }
        let baseline = kind == .percentDrop ? currentPrice : nil
        env.alerts.setAlert(ref, kind: kind, threshold: threshold, baseline: baseline)
        env.settings.priceAlertsEnabled = true
        Task { await NotificationService.requestAuthorization() }
        dismiss()
    }
}
