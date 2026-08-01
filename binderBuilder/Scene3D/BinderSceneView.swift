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
        .onAppear {
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
            if editMode { editHint } else { ownedToggleBar }
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

    /// One pocket edit: a single store transaction (which bumps the binder's
    /// changeToken), a live re-snapshot of its content, and a pool rebind so
    /// the 3D updates on the spot — without tearing the scene down, which
    /// would reset the camera and the open spread for the sake of one card.
    private func commit(binderID: String, failure: String, _ write: () -> Bool) {
        guard write() else {
            env.errors.show(failure)
            Haptics.impact(.rigid)
            return
        }
        Haptics.success()
        Task {
            await env.reloadOpenBinderContent(binderID)
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
        // An empty/absent binder falls back to the built-in debug content so
        // the scene is never blank.
        let usableContent: (any CardContentProviding)? =
            (content?.sheetCount ?? 0) > 0 ? content : nil
        result = SceneBootstrap.assemble(cardContent: usableContent, textureCache: textureCache)
    }
}
