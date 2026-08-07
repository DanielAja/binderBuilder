//
//  BinderDetailView.swift
//  binderBuilder
//
//  One binder's settings hub, pushed from the Binder manager: rename, cover
//  color, page count, and the jumps into the 3D scene / 2D grid. Sorting and
//  export stay on the manager row's context menu and the grid's toolbar.
//

import SwiftUI

struct BinderDetailView: View {
    let env: AppEnvironment
    let binderID: String

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var cover: Color = .blue
    @State private var confirmingRemovePage = false
    @State private var confirmingDelete = false

    private var binder: Binder? {
        env.binders.binders.first(where: { $0.id == binderID })
    }

    var body: some View {
        Form {
            Section("Binder") {
                TextField("Name", text: $name)
                    .onSubmit { commitRename() }
                ColorPicker("Cover color", selection: $cover, supportsOpacity: false)
                    .onChange(of: cover) { commitCover() }
            }

            Section("Pages") {
                Stepper {
                    LabeledContent("Sheets", value: "\(binder?.pageCount ?? 0)")
                } onIncrement: {
                    if env.binders.addPages(1, to: binderID) { Haptics.impact(.soft) }
                } onDecrement: {
                    requestRemoveLastPage()
                }
                LabeledContent("Cards placed",
                               value: "\(env.binders.occupiedCount(binderID: binderID))")
            }

            Section {
                Button {
                    Task {
                        await env.openBinder(binderID)
                        env.requestedTab = .binder
                    }
                } label: {
                    Label("Open in 3D", systemImage: "rotate.3d")
                }
                NavigationLink {
                    Binder2DView(env: env, binderID: binderID)
                } label: {
                    Label("Open Grid", systemImage: "square.grid.3x3")
                }
            }

            Section {
                Button("Delete Binder", role: .destructive) { confirmingDelete = true }
            }
        }
        .navigationTitle(binder?.name ?? "Binder")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            name = binder?.name ?? ""
            cover = binder.flatMap { Color(hex: $0.coverColor) } ?? .blue
        }
        .onDisappear { commitRename() }
        .confirmationDialog(
            "Remove the last page?",
            isPresented: $confirmingRemovePage,
            titleVisibility: .visible
        ) {
            Button("Remove Page", role: .destructive) { removeLastPage() }
            Button("Cancel", role: .cancel) {}
        } message: {
            let index = max((binder?.pageCount ?? 1) - 1, 0)
            let count = env.binders.assignmentCount(binderID: binderID, pageIndex: index)
            Text("\(count) card\(count == 1 ? "" : "s") will be removed from this binder. They stay in your collection.")
        }
        .confirmationDialog(
            "Delete \(binder?.name ?? "binder")?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                env.binders.deleteBinder(binderID)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the binder and its card placements. Your owned cards stay in your collection.")
        }
    }

    private func commitRename() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let binder, !trimmed.isEmpty, trimmed != binder.name else { return }
        env.binders.renameBinder(binderID, to: trimmed)
    }

    private func commitCover() {
        guard let hex = cover.hexString, hex != binder?.coverColor else { return }
        env.binders.setCoverColor(binderID, to: hex)
    }

    private func requestRemoveLastPage() {
        guard let binder, binder.pageCount > 0 else { return }
        let last = binder.pageCount - 1
        if env.binders.assignmentCount(binderID: binderID, pageIndex: last) > 0 {
            confirmingRemovePage = true
        } else {
            removeLastPage()
        }
    }

    private func removeLastPage() {
        guard let binder, binder.pageCount > 0 else { return }
        if env.binders.removePage(at: binder.pageCount - 1, from: binderID) {
            Haptics.impact(.medium)
        }
    }
}
