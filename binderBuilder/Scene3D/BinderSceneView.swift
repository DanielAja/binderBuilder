//
//  BinderSceneView.swift
//  binderBuilder
//
//  The single RealityView hosting the whole 3D experience (non-AR, virtual
//  camera). Scene content is assembled by SceneBootstrap from the injected
//  binder card content + texture cache, and owned by a SceneModel so the
//  deformers (which hold mesh/material state) stay alive.
//
//  Modes: on the SHELF, a drag orbits the camera around the shelf and a tap
//  opens the standing binder or a display case. In the OPEN BINDER, a drag
//  flips pages (or spins a floating card via arcball) and a tap pulls a card
//  out / returns it. The 3D fills the screen; the controls sit in the safe
//  area on top.
//
//  EDIT mode (the Edit toggle, open binder only) re-points the tap at the
//  pockets themselves: an occupied pocket offers Replace / Remove, an empty
//  one goes straight to the card picker. Card pull-out is suppressed while it
//  is on, so a tap is never ambiguous; page flips keep working.
//

import RealityKit
import SwiftUI

struct BinderSceneView: View {
    let env: AppEnvironment
    @State private var model: SceneModel
    @State private var sceneMode: AppMode
    /// Mirrors the floating card's ref so the toggle bar shows/hides.
    @State private var floatingRef: CardRef?
    @State private var debugDetail: CardSummary?
    @State private var debugScan = false
    /// True while a shelf-pan drag is in progress.
    @State private var panActive = false

    /// Pocket editing: taps address slots instead of cards.
    @State private var editMode = false
    /// Occupied pocket awaiting a Replace / Remove choice.
    @State private var pocketActions: PocketHit?
    /// Pocket waiting for a card from the picker sheet.
    @State private var pocketToFill: PocketHit?
    /// Edit mode: sheet index awaiting remove confirmation.
    @State private var pageToRemove: Int?

    /// Display case (shelf): empty slot awaiting a pick / occupied slot
    /// awaiting a View / Replace / Remove choice.
    @State private var displayPicker: DisplaySlot?
    @State private var displayActions: Int?

    private struct DisplaySlot: Identifiable {
        let index: Int
        var id: Int { index }
    }

    init(env: AppEnvironment) {
        self.env = env
        let scene = env.scene   // cached in AppEnvironment; survives tab switches
        _model = State(initialValue: scene)
        _sceneMode = State(initialValue: scene.result.modeController?.mode ?? .binderOpen)
    }

    var body: some View {
        ZStack {
            // Full-bleed backdrop (under the status bar / home indicator).
            LinearGradient(
                colors: [Color(white: 0.22), Color(white: 0.05)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            // 3D + controls live in the safe area so nothing collides with the
            // status bar; the backdrop shows through the RealityView elsewhere.
            sceneLayer
            controlsLayer
        }
        .sheet(item: $debugDetail) { card in
            NavigationStack { CardDetailView(card: card, env: env) }
        }
        .sheet(isPresented: $debugScan) { ScanView(env: env) }
        .sheet(item: $pocketToFill) { pocket in
            CardPickerView(env: env, title: pocket.isEmpty ? "Add to Pocket" : "Replace Card") { card in
                place(card, in: pocket)
            }
        }
        .confirmationDialog(
            "Change this card",
            isPresented: Binding(
                get: { pocketActions != nil },
                set: { if !$0 { pocketActions = nil } }),
            titleVisibility: .visible,
            presenting: pocketActions
        ) { pocket in
            // One run-loop hop so the dialog is fully dismissed before the
            // picker sheet goes up (presenting both in the same turn drops it).
            Button("Replace Card…") { Task { pocketToFill = pocket } }
            Button("Remove from Binder", role: .destructive) { empty(pocket) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $displayPicker) { slot in
            DisplayCasePickerView(env: env) { ref in
                env.binders.setDisplayCase(ref, at: slot.index)
                Haptics.success()
            }
        }
        .confirmationDialog(
            "Display case",
            isPresented: Binding(
                get: { displayActions != nil },
                set: { if !$0 { displayActions = nil } }),
            titleVisibility: .visible,
            presenting: displayActions
        ) { index in
            Button("View Card") { showDisplayedCard(at: index) }
            Button("Replace…") { Task { displayPicker = DisplaySlot(index: index) } }
            Button("Remove from Display", role: .destructive) {
                env.binders.setDisplayCase(nil, at: index)
                Haptics.impact(.medium)
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            pageToRemove.map { "Remove page \($0 + 1)?" } ?? "Remove page?",
            isPresented: Binding(
                get: { pageToRemove != nil },
                set: { if !$0 { pageToRemove = nil } }),
            titleVisibility: .visible,
            presenting: pageToRemove
        ) { sheet in
            Button("Remove Page \(sheet + 1)", role: .destructive) { removePage(sheet) }
            Button("Cancel", role: .cancel) {}
        } message: { sheet in
            let count = env.openBinderID.map {
                env.binders.assignmentCount(binderID: $0, pageIndex: sheet)
            } ?? 0
            Text(count == 0
                ? "This sheet is empty."
                : "\(count) card\(count == 1 ? "" : "s") will be removed from this binder. They stay in your collection.")
        }
        .onChange(of: env.binders.binders) { refreshShelf() }
        .onChange(of: env.binders.displayCase) { refreshShelf() }
        .onChange(of: env.binders.changeToken) {
            reconcileContentIfStale()
        }
        .onAppear {
            // Edits can land while this tab is unmounted (2D grid, card
            // detail, scans) — catch up before the first frame shows.
            reconcileContentIfStale()
            wireShelfCallbacks()
            refreshShelf()
            // Single source of truth for the owned-toggle bar: fires on every
            // pull/return, gesture-driven or programmatic (debug auto-pull
            // included), so the bar never needs bespoke bookkeeping per path.
            model.result.cardInteraction?.onFloatingChanged = { ref in floatingRef = ref }
            if DebugLaunchState.launchFlag("-showScan") { debugScan = true }
            // -editPockets: open the binder straight into pocket-edit mode, so
            // the edit affordances can be screenshot-verified.
            if DebugLaunchState.launchFlag("-editPockets"), sceneMode != .shelf {
                setEditMode(true)
            }
            if DebugLaunchState.launchFlag("-showCardDetail") {
                Task {
                    if let detail = try? await env.catalog?.card(id: "base1-4") {
                        debugDetail = detail.summary
                    }
                }
            }
        }
    }

    // MARK: Full-bleed 3D + gestures

    private var sceneLayer: some View {
        GeometryReader { proxy in
            RealityView { content in
                content.camera = .virtual
                content.add(model.result.root)
            }
            // Framings are solved for the live viewport aspect: snap on first
            // layout, dolly on later changes (rotation, iPad multitasking).
            .onAppear { model.result.cameraRig.setViewport(proxy.size, animated: false) }
            .onChange(of: proxy.size) { _, size in
                model.result.cameraRig.setViewport(size, animated: true)
            }
            .gesture(
                // >0 minimum so a tap never starts a drag; the tap gesture owns
                // open/pull-out/return. Shelf: drag orbits the camera. Binder:
                // drag flips a page or (while a card floats) spins it.
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        if sceneMode == .shelf {
                            if !panActive { model.result.modeController?.beginShelfPan(); panActive = true }
                            model.result.modeController?.updateShelfPan(
                                translation: value.translation, viewport: proxy.size
                            )
                            return
                        }
                        if model.result.cardInteraction?.isFloating == true {
                            model.result.cardInteraction?.dragChanged(
                                location: value.location, viewport: proxy.size
                            )
                        } else {
                            model.result.router?.dragChanged(
                                location: value.location,
                                startLocation: value.startLocation,
                                translation: value.translation,
                                viewport: proxy.size
                            )
                        }
                    }
                    .onEnded { value in
                        if sceneMode == .shelf { panActive = false; return }
                        let v = CGSize(width: value.velocity.width, height: value.velocity.height)
                        if model.result.cardInteraction?.isFloating == true {
                            model.result.cardInteraction?.dragEnded(velocity: v, viewport: proxy.size)
                        } else {
                            model.result.router?.dragEnded(
                                translation: value.translation, velocity: v, viewport: proxy.size
                            )
                        }
                    }
            )
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        if model.result.modeController?.isShelf == true {
                            let ray = model.result.cameraRig.ray(through: value.location, viewport: proxy.size)
                            model.result.modeController?.handleShelfTap(
                                origin: ray.origin, direction: ray.direction
                            )
                        } else if editMode {
                            // Edit mode owns the tap outright: pulling a card
                            // out would fight with "which pocket did I mean?".
                            handleEditTap(at: value.location, viewport: proxy.size)
                        } else {
                            model.result.cardInteraction?.handleTap(at: value.location, viewport: proxy.size)
                        }
                        sceneMode = model.result.modeController?.mode ?? sceneMode
                    }
            )
        }
    }

    // MARK: Controls (safe area)

    private var controlsLayer: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                if sceneMode != .shelf {
                    shelfButton
                    Spacer()
                    editButton
                } else {
                    Spacer()
                }
            }
            Spacer()
            if editMode {
                VStack(spacing: 10) {
                    pageEditBar
                    editHint
                }
            } else if binderNeedsPages {
                addPagesCTA
            } else {
                ownedToggleBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private var shelfButton: some View {
        Button {
            model.result.modeController?.enterShelf()
            sceneMode = .shelf
            floatingRef = nil
            setEditMode(false)
        } label: {
            Label("Shelf", systemImage: "books.vertical.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .floatingGlass()
        }
        .tint(.white)
        .accessibilityLabel("View shelf")
        .accessibilityHint("Shows your binders and display case")
    }

    // MARK: Pocket editing

    private var editButton: some View {
        Button {
            setEditMode(!editMode)
        } label: {
            Label(editMode ? "Done" : "Edit",
                  systemImage: editMode ? "checkmark" : "square.grid.3x3.square")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .floatingGlass()
        }
        .tint(editMode ? .yellow : .white)
        .accessibilityLabel(editMode ? "Done editing pockets" : "Edit pockets")
        .accessibilityHint(editMode
            ? "Stops editing, so tapping a card lifts it out again"
            : "Lets you tap a pocket to add, replace, or remove its card")
        .accessibilityAddTraits(editMode ? [.isSelected] : [])
    }

    /// Edit-mode page controls: insert a sheet at the open spread / remove
    /// the sheet on the right (with an occupied-count confirmation).
    private var pageEditBar: some View {
        HStack(spacing: 12) {
            Button {
                if let sheet = currentEditSheet { pageToRemove = sheet }
            } label: {
                Label("Page", systemImage: "minus.rectangle.portrait")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .floatingGlass()
            }
            .tint(.white)
            .disabled(currentEditSheet == nil)
            .accessibilityLabel("Remove this page")

            Button {
                insertPageAtCurrentSpread()
            } label: {
                Label("Page", systemImage: "plus.rectangle.portrait")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .floatingGlass()
            }
            .tint(.white)
            .accessibilityLabel("Add a page here")
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// True when the open binder has no sheets — real users should see a way
    /// forward, never a blank slab (or worse, debug demo cards).
    private var binderNeedsPages: Bool {
        guard sceneMode != .shelf, let binderID = env.openBinderID,
              let binder = env.binders.binders.first(where: { $0.id == binderID }) else { return false }
        return binder.pageCount == 0
    }

    private var addPagesCTA: some View {
        Button {
            guard let binderID = env.openBinderID else { return }
            if env.binders.addPages(1, to: binderID) { Haptics.impact(.soft) }
        } label: {
            Label("Add pages to start", systemImage: "plus.rectangle.portrait")
                .font(.headline)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .floatingGlass()
        }
        .tint(.white)
        .accessibilityHint("Adds the binder's first page")
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var editHint: some View {
        Text("Tap a pocket to change its card")
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 18).padding(.vertical, 12)
            .floatingGlass()
            .foregroundStyle(.white)
            .accessibilityHidden(true)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func setEditMode(_ on: Bool) {
        guard on != editMode else { return }
        editMode = on
        // Nothing may hover in front of the camera while taps mean "edit this
        // pocket" — the floating card would swallow them.
        if on { model.result.cardInteraction?.returnFloatingCard() }
        pocketActions = nil
        pocketToFill = nil
        Haptics.selection()
    }

    private func handleEditTap(at point: CGPoint, viewport: CGSize) {
        let picker = PocketPicker(root: model.result.root, cameraRig: model.result.cameraRig)
        guard let pocket = picker.pick(at: point, viewport: viewport) else { return }
        Haptics.impact(.light)
        // An empty pocket has only one sensible action, so skip the menu.
        if pocket.isEmpty { pocketToFill = pocket } else { pocketActions = pocket }
    }

    private func place(_ card: CardSummary, in pocket: PocketHit) {
        guard let binderID = env.openBinderID else { return }
        // Prefer a printing the user already owns, so the pocket renders in
        // color; otherwise the plain print. Duplicates elsewhere in the binder
        // are fine — people own multiples.
        let variant = CardVariant.allCases.first {
            env.collection.isOwned(CardRef(cardID: card.id, variant: $0))
        } ?? .normal
        let ref = CardRef(cardID: card.id, variant: variant)
        commit(binderID: binderID, failure: "Couldn't put \(card.name) in that pocket.") {
            env.binders.setSlot(ref, at: pocket.location(binderID: binderID))
        }
    }

    private func empty(_ pocket: PocketHit) {
        guard let binderID = env.openBinderID else { return }
        commit(binderID: binderID, failure: "Couldn't empty that pocket.") {
            env.binders.clearSlot(pocket.location(binderID: binderID))
        }
    }

    /// One pocket edit: a single store transaction. The write bumps the
    /// binder's changeToken, and the token observer above owns the re-snapshot
    /// + pool rebind — every write path refreshes the scene through that one
    /// funnel, so none can forget to.
    private func commit(binderID: String, failure: String, _ write: () -> Bool) {
        guard write() else {
            env.errors.show(failure)
            Haptics.impact(.rigid)
            return
        }
        Haptics.success()
    }

    // MARK: Shelf (data-driven rows + tap routing)

    /// Rebuilds the shelf's binder + display rows from the stores (cheap; the
    /// controller skips rebuilds when nothing changed).
    private func refreshShelf() {
        guard let shelf = model.result.shelfController else { return }
        shelf.refreshBinders(env.binders.binders, openBinderID: env.openBinderID)
        Task {
            let contents = await env.binders.displayCaseContents()
            shelf.refreshDisplayCases(contents, maxCount: BinderStore.displayCaseMaxCount)
        }
    }

    private func wireShelfCallbacks() {
        guard let modeController = model.result.modeController else { return }
        modeController.onOpenBinder = { id in openBinderFromShelf(id) }
        modeController.onTapDisplayCase = { index in
            Haptics.impact(.light)
            let occupied = env.binders.displayCase.indices.contains(index)
                && env.binders.displayCase[index] != nil
            if occupied { displayActions = index } else { displayPicker = DisplaySlot(index: index) }
        }
        modeController.onTapAddDisplay = {
            if env.binders.setDisplayCaseCount(env.binders.displayCaseCount + 1) {
                Haptics.success()
            }
        }
    }

    /// Pull-and-turn: the tapped binder slides toward the camera with a
    /// slight turn, the content switches IN PLACE (no scene rebuild — the
    /// flip controller reads sheetCount live), and the camera dollies in
    /// while the roots crossfade. The shelf pose resets once hidden.
    private func openBinderFromShelf(_ binderID: String) {
        guard let modeController = model.result.modeController else { return }
        Haptics.impact(.medium)
        let entity = model.result.shelfController?.binderEntity(id: binderID)
        if let entity {
            var transform = entity.transform
            transform.translation += SIMD3<Float>(0, 0.015, 0.12)
            transform.rotation = simd_quatf(angle: 0.18, axis: SIMD3<Float>(0, 1, 0)) * transform.rotation
            entity.move(to: transform, relativeTo: entity.parent, duration: 0.25, timingFunction: .easeInOut)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            await env.openBinder(binderID)
            if let controller = model.result.controller {
                controller.rebind(spread: controller.sheetCount / 2)
            }
            modeController.enterBinder()
            sceneMode = .binderOpen
            // Put the pulled binder back once the crossfade has hidden the
            // shelf, so returning shows it seated again.
            try? await Task.sleep(for: .milliseconds(450))
            model.result.shelfController?.resetBinderPose(id: binderID)
        }
    }

    private func showDisplayedCard(at index: Int) {
        guard env.binders.displayCase.indices.contains(index),
              let ref = env.binders.displayCase[index] else { return }
        Task {
            if let detail = try? await env.catalog?.card(id: ref.cardID) {
                debugDetail = detail.summary
            }
        }
    }

    // MARK: Page add/remove (edit mode)

    /// The sheet the "remove" button targets: the right page's sheet, or the
    /// last sheet when the binder is open at the very back.
    private var currentEditSheet: Int? {
        guard let binderID = env.openBinderID,
              let binder = env.binders.binders.first(where: { $0.id == binderID }),
              binder.pageCount > 0,
              let controller = model.result.controller else { return nil }
        return min(controller.spreadIndex, binder.pageCount - 1)
    }

    private func insertPageAtCurrentSpread() {
        guard let binderID = env.openBinderID,
              let binder = env.binders.binders.first(where: { $0.id == binderID }),
              let controller = model.result.controller else { return }
        let at = min(controller.spreadIndex, binder.pageCount)
        guard env.binders.insertPage(at: at, in: binderID) else { return }
        Haptics.impact(.soft)
    }

    private func removePage(_ sheet: Int) {
        guard let binderID = env.openBinderID else { return }
        guard env.binders.removePage(at: sheet, from: binderID) else {
            env.errors.show("Couldn't remove that page.")
            return
        }
        Haptics.impact(.medium)
    }

    /// The single owner of 3D content refresh: when the store's changeToken
    /// has moved past the snapshot the scene renders (`env.contentToken`),
    /// re-point at a surviving binder if needed, re-snapshot in place, and
    /// rebind the page pool. Camera and open spread survive (`rebind` clamps).
    private func reconcileContentIfStale() {
        guard env.binders.changeToken != env.contentToken else { return }
        Task {
            await env.reconcileOpenBinder()
            if let id = env.openBinderID {
                await env.reloadOpenBinderContent(id)
            }
            if let controller = model.result.controller {
                controller.rebind(spread: controller.spreadIndex)
            }
        }
    }

    @ViewBuilder
    private var ownedToggleBar: some View {
        if let ref = floatingRef {
            let owned = env.collection.isOwned(ref)
            Button {
                let nowOwned = env.toggleOwned(ref)
                model.result.cardInteraction?.setFloatingOwned(nowOwned)
            } label: {
                Label(owned ? "In collection" : "Not in collection",
                      systemImage: owned ? "checkmark.seal.fill" : "circle.dashed")
                    .font(.headline)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .floatingGlass()
            }
            .tint(owned ? .green : .secondary)
            .accessibilityHint("Toggles whether this card is in your collection")
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

@MainActor
@Observable
final class SceneModel {
    let result: SceneBootstrapResult

    init(content: (any CardContentProviding)?, textureCache: CardTextureCache?) {
        // Real content always drives the scene — an empty binder renders as
        // covers + an "add pages" call to action, never as fabricated cards.
        // -debugContent forces the built-in debug sheets (screenshot harness,
        // shader spot checks); assemble also falls back to them when it gets
        // nil (unit tests exercising the scene without a store).
        let usableContent: (any CardContentProviding)? =
            DebugLaunchState.launchFlag("-debugContent") ? nil : content
        result = SceneBootstrap.assemble(cardContent: usableContent, textureCache: textureCache)
    }
}
