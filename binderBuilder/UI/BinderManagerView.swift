//
//  BinderManagerView.swift
//  binderBuilder
//
//  Create, rename, and delete binders, and a quick collection summary. (The
//  3D scene renders the first binder; choosing which binder to open in 3D is a
//  later enhancement.)
//

import SwiftUI

struct BinderManagerView: View {
    let env: AppEnvironment

    @State private var showingCreate = false
    @State private var newName = ""
    @State private var renaming: Binder?
    @State private var renameText = ""

    var body: some View {
        List {
            Section("Collection") {
                Label("\(env.collection.ownedCount) cards owned", systemImage: "checkmark.seal.fill")
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
                        Button("Delete", role: .destructive) { env.binders.deleteBinder(binder.id) }
                    }
                }
                .onDelete { offsets in
                    for index in offsets { env.binders.deleteBinder(env.binders.binders[index].id) }
                }
            }
        }
        .navigationTitle("Binders")
        .toolbar {
            Button { newName = ""; showingCreate = true } label: { Image(systemName: "plus") }
        }
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
