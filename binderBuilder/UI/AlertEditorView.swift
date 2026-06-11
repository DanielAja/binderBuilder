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

    private var existing: PriceAlert? { env.alerts.alert(for: ref) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Alert when", selection: $kind) {
                        Text("Drops below price").tag(AlertKind.belowTarget)
                        Text("Drops by percent").tag(AlertKind.percentDrop)
                    }
                    HStack {
                        Text(kind == .belowTarget ? "Target price" : "Percent drop")
                        TextField(kind == .belowTarget ? "0.00" : "10", text: $thresholdText)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
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
            .navigationTitle("Price Alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!canSave) }
            }
            .onAppear {
                if let existing {
                    kind = existing.kind
                    thresholdText = String(existing.threshold)
                }
            }
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
