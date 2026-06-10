//
//  CopyEditorView.swift
//  binderBuilder
//
//  Add or edit one physical copy: condition, optional professional grade,
//  acquisition price, and notes. Writes through CollectionStore (per-copy).
//

import SwiftUI

struct CopyEditorView: View {
    let ref: CardRef
    let env: AppEnvironment
    /// nil = add a new copy; non-nil = edit.
    var existing: CardCopy?

    @Environment(\.dismiss) private var dismiss
    @State private var condition: CardCondition = .nm
    @State private var isGraded = false
    @State private var company: GradeCompany = .psa
    @State private var gradeValue = 10.0
    @State private var acquiredPrice = ""
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Condition") {
                    Picker("Condition", selection: $condition) {
                        ForEach(CardCondition.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
                Section("Grading") {
                    Toggle("Professionally graded", isOn: $isGraded)
                    if isGraded {
                        Picker("Company", selection: $company) {
                            ForEach(GradeCompany.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Stepper(value: $gradeValue, in: 1...10, step: 0.5) {
                            HStack { Text("Grade"); Spacer()
                                Text(gradeValue == gradeValue.rounded() ? "\(Int(gradeValue))" : "\(gradeValue, specifier: "%.1f")")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Details") {
                    HStack {
                        Text("Paid")
                        TextField("0.00", text: $acquiredPrice)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(1...4)
                }
                if existing != nil {
                    Section {
                        Button("Delete this copy", role: .destructive) {
                            env.collection.removeCopy(existing!.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "Add Copy" : "Edit Copy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
            .onAppear(perform: loadExisting)
        }
    }

    private func loadExisting() {
        guard let copy = existing else { return }
        condition = copy.condition
        if let grade = copy.grade { isGraded = true; company = grade.company; gradeValue = grade.value }
        if let price = copy.acquiredPrice { acquiredPrice = String(price) }
        notes = copy.notes ?? ""
    }

    private func save() {
        let grade = isGraded ? CardGrade(company: company, value: gradeValue) : nil
        let price = Double(acquiredPrice.trimmingCharacters(in: .whitespaces))
        let trimmedNotes = notes.trimmingCharacters(in: .whitespaces)
        if var copy = existing {
            copy.condition = condition
            copy.grade = grade
            copy.acquiredPrice = price
            copy.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
            env.collection.updateCopy(copy)
        } else {
            env.collection.addCopy(ref, condition: condition, grade: grade,
                                   acquiredPrice: price, notes: trimmedNotes.isEmpty ? nil : trimmedNotes)
        }
        dismiss()
    }
}
