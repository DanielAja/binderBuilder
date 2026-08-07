//
//  Binder2DView.swift
//  binderBuilder
//
//  The 2D binder editor: every page side as a 3x3 grid in one scroll.
//
//  Browse mode — tap an empty pocket to fill it from the card picker; tap an
//  occupied one for View / Replace / Move / Remove. "Move" is the tap-based
//  path (HIG: every drag action needs a non-drag equivalent): pick the card,
//  then tap its destination.
//
//  Arrange mode — pockets wobble and become draggable. While a card hovers,
//  the grid previews the final arrangement (swap, or the gap-absorbing
//  insert-&-shift ripple — a segmented toggle picks which); the drop commits
//  one BinderStore.moveCard. Undo restores whole-binder snapshots.
//
//  Writes go through Binder2DModel -> BinderStore, whose changeToken this
//  view and the 3D scene both observe — the two stay in sync for free.
//

import SwiftUI
import UniformTypeIdentifiers

struct Binder2DView: View {
    let env: AppEnvironment
    /// Present when this view sits in the Binder tab: binds the 3D | Grid
    /// switch rendered in the toolbar. nil when pushed from Binder manager.
    var showGrid: Binding<Bool>?

    @State private var model: Binder2DModel

    // Browse-mode interactions.
    @State private var pickerTarget: SlotLocation?
    @State private var occupiedTarget: OccupiedSlot?
    @State private var detailCard: CardSummary?
    /// Tap-based move: the source pocket awaiting a destination tap.
    @State private var moveSource: SlotLocation?

    // Arrange mode.
    @State private var arrangeMode = false
    @State private var moveMode: SlotMoveMode = .insertShift
    @State private var dragSourceOrdinal: Int?
    @State private var previewPages: [Binder2DModel.PageSideModel]?
    @State private var previewTargetOrdinal: Int?

    // Page ops.
    @State private var pageToRemove: Int?

    private struct OccupiedSlot: Identifiable {
        let location: SlotLocation
        let content: SlotContent
        var id: SlotLocation { location }
    }

    init(env: AppEnvironment, binderID: String, showGrid: Binding<Bool>? = nil) {
        self.env = env
        self.showGrid = showGrid
        _model = State(initialValue: Binder2DModel(store: env.binders, binderID: binderID))
    }

    var body: some View {
        Group {
            if model.pages.isEmpty && !model.isLoading {
                emptyBinder
            } else {
                pageList
            }
        }
        .navigationTitle(model.binder?.name ?? "Binder")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sensoryFeedback(.alignment, trigger: previewTargetOrdinal)
        .task { await model.reload() }
        .onChange(of: env.binders.changeToken) {
            Task { await model.reloadIfNeeded() }
        }
        .onChange(of: arrangeMode) {
            resetDragState()
            moveSource = nil
            Haptics.selection()
        }
        .sheet(item: $pickerTarget) { slot in
            CardPickerView(env: env, title: "Add to Pocket") { card in
                fill(slot, with: card)
            }
        }
        .sheet(item: $detailCard) { card in
            NavigationStack { CardDetailView(card: card, env: env) }
        }
        .confirmationDialog(
            occupiedTarget.map { "\($0.content.card.name)" } ?? "Card",
            isPresented: Binding(
                get: { occupiedTarget != nil },
                set: { if !$0 { occupiedTarget = nil } }),
            titleVisibility: .visible,
            presenting: occupiedTarget
        ) { slot in
            Button("View Card") { Task { detailCard = slot.content.card } }
            Button("Replace…") { Task { pickerTarget = slot.location } }
            Button("Move…") { beginTapMove(from: slot.location) }
            Button("Remove from Binder", role: .destructive) { remove(slot.location) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            removePageTitle,
            isPresented: Binding(
                get: { pageToRemove != nil },
                set: { if !$0 { pageToRemove = nil } }),
            titleVisibility: .visible,
            presenting: pageToRemove
        ) { page in
            Button("Remove Page \(page + 1)", role: .destructive) { removePage(page) }
            Button("Cancel", role: .cancel) {}
        } message: { page in
            let count = model.assignmentCount(pageIndex: page)
            Text(count == 0
                ? "This sheet is empty."
                : "\(count) card\(count == 1 ? "" : "s") will be removed from this binder. They stay in your collection.")
        }
    }

    // MARK: - Page list

    private var displayPages: [Binder2DModel.PageSideModel] {
        previewPages ?? model.pages
    }

    private var pageList: some View {
        ScrollView {
            LazyVStack(spacing: 22) {
                ForEach(displayPages) { page in
                    pageSection(page)
                }
                addPageFooter
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
        // A drop that ends outside every pocket (or is cancelled) must not
        // leave a stale preview or a stuck drag source.
        .onDrop(of: [.plainText], delegate: ResetDropDelegate(reset: resetDragState))
    }

    private func pageSection(_ page: Binder2DModel.PageSideModel) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(page.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !arrangeMode {
                    Menu {
                        Button("Insert Page Before") { insertPage(at: page.pageIndex) }
                        Button("Insert Page After") { insertPage(at: page.pageIndex + 1) }
                        Button("Remove Page…", role: .destructive) { pageToRemove = page.pageIndex }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Page \(page.pageIndex + 1) options")
                }
            }
            BinderPageGridView(slots: page.slots) { index, content in
                pocketCell(page: page, index: index, content: content)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    @ViewBuilder
    private func pocketCell(page: Binder2DModel.PageSideModel, index: Int, content: SlotContent?) -> some View {
        let location = model.location(page: page, index: index)
        let ordinal = BinderStore.ordinal(of: location)
        let cell = Pocket2DCell(
            content: content,
            imageCache: env.imageCache,
            jiggle: arrangeMode,
            jigglePhase: index,
            highlighted: moveSource == location)
            .accessibilityLabel(pocketLabel(page: page, index: index, content: content))

        if arrangeMode {
            cell
                .onDrag {
                    dragSourceOrdinal = ordinal
                    return NSItemProvider(object: "\(ordinal)" as NSString)
                }
                .onDrop(of: [.plainText], delegate: PocketDropDelegate(
                    target: ordinal,
                    dragSourceOrdinal: $dragSourceOrdinal,
                    previewPages: $previewPages,
                    previewTargetOrdinal: $previewTargetOrdinal,
                    basePages: { model.pages },
                    mode: { moveMode },
                    commit: { source, target in commitDrag(from: source, to: target) }))
        } else {
            Button {
                handleTap(location, content: content)
            } label: {
                cell
            }
            .buttonStyle(.plain)
            .accessibilityHint(content == nil ? "Adds a card to this pocket" : "Shows actions for this card")
        }
    }

    private func pocketLabel(page: Binder2DModel.PageSideModel, index: Int, content: SlotContent?) -> String {
        let place = "page \(page.pageIndex + 1) \(page.side == .front ? "front" : "back"), pocket \(index + 1)"
        return content.map { "\($0.card.name), \(place)" } ?? "Empty pocket, \(place)"
    }

    @ViewBuilder
    private var addPageFooter: some View {
        if !arrangeMode {
            Button {
                addPage()
            } label: {
                Label("Add Page", systemImage: "plus.rectangle.portrait")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var emptyBinder: some View {
        ContentUnavailableView {
            Label("No Pages Yet", systemImage: "book.closed")
        } description: {
            Text("Add a page to start placing cards.")
        } actions: {
            Button("Add a Page") { addPage() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Toolbar + bottom bar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let showGrid {
            ToolbarItem(placement: .principal) {
                viewTogglePicker(showGrid)
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if model.canUndo {
                Button {
                    undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .accessibilityLabel("Undo last change")
            }
            Button(arrangeMode ? "Done" : "Arrange") {
                arrangeMode.toggle()
            }
            .fontWeight(arrangeMode ? .semibold : .regular)
            .accessibilityHint(arrangeMode
                ? "Stops rearranging"
                : "Lets you drag cards between pockets")
        }
    }

    private func viewTogglePicker(_ binding: Binding<Bool>) -> some View {
        Picker("View", selection: binding) {
            Text("3D").tag(false)
            Text("Grid").tag(true)
        }
        .pickerStyle(.segmented)
        .frame(width: 130)
        .accessibilityLabel("Binder view style")
    }

    @ViewBuilder
    private var bottomBar: some View {
        if arrangeMode {
            VStack(spacing: 6) {
                Picker("Move style", selection: $moveMode) {
                    Text("Insert & Shift").tag(SlotMoveMode.insertShift)
                    Text("Swap").tag(SlotMoveMode.swap)
                }
                .pickerStyle(.segmented)
                Text(moveMode == .insertShift
                    ? "Drop a card and the others ripple forward."
                    : "Drop a card to trade places.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .floatingGlass()
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let source = moveSource {
            HStack(spacing: 12) {
                Text("Tap a pocket to move the card there")
                    .font(.subheadline.weight(.medium))
                Picker("Move style", selection: $moveMode) {
                    Text("Shift").tag(SlotMoveMode.insertShift)
                    Text("Swap").tag(SlotMoveMode.swap)
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
                Button("Cancel") { moveSource = nil }
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .floatingGlass()
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(source)   // re-animates when a new move starts
        }
    }

    private var removePageTitle: String {
        pageToRemove.map { "Remove page \($0 + 1)?" } ?? "Remove page?"
    }

    // MARK: - Actions

    private func handleTap(_ location: SlotLocation, content: SlotContent?) {
        if let source = moveSource {
            moveSource = nil
            guard source != location else { return }
            commitMove(from: source, to: location)
            return
        }
        if let content {
            occupiedTarget = OccupiedSlot(location: location, content: content)
        } else {
            pickerTarget = location
        }
    }

    private func beginTapMove(from location: SlotLocation) {
        // Hop a run loop so the dialog fully dismisses before the hint bar
        // animates in (same pattern as the 3D pocket editor's sheets).
        Task { moveSource = location }
    }

    private func fill(_ slot: SlotLocation, with card: CardSummary) {
        // Prefer a printing the user owns so the pocket renders in color.
        let variant = CardVariant.allCases.first {
            env.collection.isOwned(CardRef(cardID: card.id, variant: $0))
        } ?? .normal
        guard model.fill(slot, with: CardRef(cardID: card.id, variant: variant)) else {
            env.errors.show("Couldn't put \(card.name) in that pocket.")
            Haptics.impact(.rigid)
            return
        }
        Haptics.success()
    }

    private func remove(_ slot: SlotLocation) {
        guard model.remove(at: slot) else {
            env.errors.show("Couldn't empty that pocket.")
            Haptics.impact(.rigid)
            return
        }
        Haptics.impact(.medium)
    }

    private func commitMove(from: SlotLocation, to: SlotLocation) {
        guard model.move(from: from, to: to, mode: moveMode) != nil else {
            env.errors.show(moveMode == .insertShift
                ? "No room to shift — the binder is full. Add a page first."
                : "Couldn't move that card.")
            Haptics.impact(.rigid)
            return
        }
        Haptics.success()
    }

    private func commitDrag(from source: Int, to target: Int) {
        let binderID = model.binderID
        resetDragState()
        guard source != target else { return }
        commitMove(
            from: BinderStore.slotLocation(atOrdinal: source, binderID: binderID),
            to: BinderStore.slotLocation(atOrdinal: target, binderID: binderID))
    }

    private func undo() {
        guard model.undo() else { return }
        Haptics.impact(.light)
    }

    private func addPage() {
        guard model.addPage() else { return }
        Haptics.impact(.soft)
    }

    private func insertPage(at index: Int) {
        guard model.insertPage(at: index) else { return }
        Haptics.impact(.soft)
    }

    private func removePage(_ index: Int) {
        guard model.removePage(at: index) else {
            env.errors.show("Couldn't remove that page.")
            return
        }
        Haptics.impact(.medium)
    }

    private func resetDragState() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            previewPages = nil
        }
        dragSourceOrdinal = nil
        previewTargetOrdinal = nil
    }
}

// MARK: - Drop delegates

/// One pocket as a drop target: hovering previews the final arrangement
/// (recomputed from the authoritative pages each time, so previews never
/// compound), dropping commits a single store move.
private struct PocketDropDelegate: DropDelegate {
    let target: Int
    @Binding var dragSourceOrdinal: Int?
    @Binding var previewPages: [Binder2DModel.PageSideModel]?
    @Binding var previewTargetOrdinal: Int?
    let basePages: () -> [Binder2DModel.PageSideModel]
    let mode: () -> SlotMoveMode
    let commit: (Int, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let source = dragSourceOrdinal, source != target else { return }
        let base = basePages()
        let flat = Binder2DModel.flattened(base)
        guard let applied = Binder2DModel.applyMovePreview(
            flat, from: source, to: target, mode: mode()) else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            previewPages = Binder2DModel.rechunk(applied, like: base)
        }
        previewTargetOrdinal = target
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let source = dragSourceOrdinal else { return false }
        commit(source, target)
        return true
    }
}

/// Catches drops that end outside every pocket so the preview and drag state
/// never stick around after a cancelled drag.
private struct ResetDropDelegate: DropDelegate {
    let reset: () -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        reset()
        return false
    }
}

extension SlotLocation: Identifiable {
    var id: String { "\(binderID)-\(pageIndex)-\(side.rawValue)-\(slotIndex)" }
}
