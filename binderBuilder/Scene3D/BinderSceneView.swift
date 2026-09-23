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
//  FOLD. On a folding device the scene is staged around the crease rather
//  than around the screen: the binder's spine goes where the hardware bends,
//  the camera swings overhead as the hinge closes so each page ends up
//  square-on to its own panel, and the floating controls step off the fold.
//  The policy lives in BinderStage; this view reads the crease from its own
//  geometry proxy (crease rects are per-coordinate-space) and applies it.
//

import RealityKit
import SwiftUI

struct BinderSceneView: View {
    let env: AppEnvironment
    /// Device-wide fold (hinge angle, whether we're on the outer display).
    @Environment(\.fold) private var fold
    /// The fold as measured in the scene's own coordinate space — this is
    /// the one the camera and the controls are laid out against.
    @State private var sceneFold = FoldState.none
    @State private var model: SceneModel
    @State private var sceneMode: AppMode
    /// Mirrors the floating card's ref so the toggle bar shows/hides.
    @State private var floatingRef: CardRef?
    @State private var debugDetail: CardSummary?
    @State private var debugScan = false
    /// True while a shelf-pan drag is in progress.
    @State private var panActive = false
    /// True while a pinch is in progress, so the one-finger drag handlers stand
    /// down — SwiftUI still feeds a DragGesture from a two-finger pinch, and
    /// without this a zoom would flip pages under the fingers.
    @State private var zoomActive = false
    /// Mirrors the rig's zoom so the reset control can appear when it matters.
    @State private var zoomLevel: Float = 1
    /// Width the top row actually gets. The 3D/Grid toggle floats over its
    /// middle (BinderTabView), so the labelled buttons only fit when there's
    /// room either side of it — see `topRowIsCompact`.
    @State private var controlsWidth: CGFloat = 0
    /// True from the shelf tap until the crossfade has hidden the shelf, so
    /// nothing rebuilds the row out from under the pull-out animation.
    @State private var openingFromShelf = false

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

    /// Quick export from the 3D view (current spread / whole binder).
    @State private var exporter = BinderExportRunner()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// Between onAppear and onDisappear. The scene outlives this view across
    /// tab switches, so "is anyone looking?" has to be tracked here.
    @State private var isVisible = false
    /// Low Power Mode freezes the foil like Reduce Motion does: CoreMotion
    /// at 60 Hz for a hue shift is the first thing to give up.
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// Mirrors the flip controller's spread for the VoiceOver value.
    @State private var spreadIndex = 0

    /// True while SwiftUI considers each gesture live. @GestureState resets
    /// on cancellation too, which onEnded does not report — see
    /// `settleCancelledGestures`.
    @GestureState private var dragInFlight = false
    @GestureState private var pinchInFlight = false

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
        // Which binder is open decides which one stands face-out on the shelf
        // (ShelfLayout.binderPlacements), so the row is stale until this fires.
        .onChange(of: env.openBinderID) { refreshShelf() }
        // "Open in 3D" from another screen swaps the content snapshot without
        // touching the store's changeToken, so the staleness reconcile below
        // sees nothing to do. Follow the snapshot's binder instead of the
        // open ID: the ID flips before the new snapshot lands.
        .onChange(of: env.contentBinderID) { syncPoolBinding() }
        .overlay {
            if exporter.isRunning {
                ProgressView("Exporting…", value: exporter.progress)
                    .progressViewStyle(.linear)
                    .padding(20)
                    .frame(maxWidth: 260)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .sheet(item: Binding(get: { exporter.share }, set: { exporter.share = $0 })) { share in
            ExportShareSheet(urls: share.urls)
        }
        .onChange(of: env.binders.changeToken) {
            reconcileContentIfStale()
        }
        .onChange(of: reduceMotion) { applyMotionPolicy() }
        .onChange(of: lowPower) { applyMotionPolicy() }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding cancels touches without onEnded; settle them
            // now rather than on return, when the stale state would bite.
            if phase != .active { settleCancelledGestures() }
            applyMotionPolicy()
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: .NSProcessInfoPowerStateDidChange) {
                lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
        .onDisappear {
            isVisible = false
            settleCancelledGestures()
            applyMotionPolicy()
        }
        .onAppear {
            isVisible = true
            applyMotionPolicy()
            // Edits can land while this tab is unmounted (2D grid, card
            // detail, scans) — catch up before the first frame shows.
            reconcileContentIfStale()
            // …and so can a binder switch ("Open in 3D" from the binder's
            // settings), whose onChange never fired while we were gone.
            syncPoolBinding()
            wireShelfCallbacks()
            refreshShelf()
            // The scene (and its rig) outlives this view across tab switches.
            zoomLevel = model.result.cameraRig.zoom
            if let debugZoom = DebugLaunchState.current.zoom {
                model.result.cameraRig.beginZoom()
                model.result.cameraRig.updateZoom(magnification: CGFloat(debugZoom))
                model.result.cameraRig.endZoom()
                zoomLevel = model.result.cameraRig.zoom
            }
            // Single source of truth for the owned-toggle bar: fires on every
            // pull/return, gesture-driven or programmatic (debug auto-pull
            // included), so the bar never needs bespoke bookkeeping per path.
            model.result.cardInteraction?.onFloatingChanged = { ref in floatingRef = ref }
            // The callback only reports changes, and this view's @State
            // started over when the tab came back (3D -> Grid -> 3D) while the
            // scene — and a card still floating in it — did not.
            floatingRef = model.result.cardInteraction?.floatingRef
            model.result.controller?.onSpreadChanged = { spread in spreadIndex = spread }
            spreadIndex = model.result.controller?.spreadIndex ?? 0
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
            // Crease rects are only meaningful in the proxy that reported
            // them, so the scene reads its own rather than the root's.
            let localFold = FoldSupport.fold(in: proxy, hinge: fold)
            RealityView { content in
                content.camera = .virtual
                content.add(model.result.root)
            }
            // The stage is solved for the live viewport AND the fold: snap on
            // first layout, dolly on later changes (rotation, iPad
            // multitasking, and the hinge opening or closing).
            .onAppear { applyStage(localFold, animated: false) }
            .onChange(of: localFold) { _, new in applyStage(new, animated: true) }
            .gesture(
                // >0 minimum so a tap never starts a drag; the tap gesture owns
                // open/pull-out/return. Shelf: drag orbits the camera. Binder:
                // drag flips a page or (while a card floats) spins it.
                DragGesture(minimumDistance: 8)
                    .updating($dragInFlight) { _, inFlight, _ in inFlight = true }
                    .onChanged { value in
                        if zoomActive { return }
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
                        if zoomActive { return }
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
                // Pinch to zoom, in both scenes. The rig re-solves its framing
                // distance, so the shelf orbit and the open binder's angle are
                // preserved — only the dolly moves.
                MagnifyGesture(minimumScaleDelta: 0.01)
                    .updating($pinchInFlight) { _, inFlight, _ in inFlight = true }
                    .onChanged { value in
                        if !zoomActive {
                            // A floating card is pinned a fixed distance in
                            // front of where the camera WAS; dollying past it
                            // puts it behind the lens (or fills the screen
                            // with its edge). Inspecting a card is its own
                            // zoom, so the pinch simply stands down.
                            if model.result.cardInteraction?.isFloating == true { return }
                            beginZoom(viewport: proxy.size)
                        }
                        model.result.cameraRig.updateZoom(magnification: value.magnification)
                        zoomLevel = model.result.cameraRig.zoom
                    }
                    .onEnded { _ in
                        guard zoomActive else { return }
                        model.result.cameraRig.endZoom()
                        zoomLevel = model.result.cameraRig.zoom
                        zoomActive = false
                        Haptics.selection()
                    }
            )
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        if zoomActive { return }
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
            // Cancellation resets @GestureState but never calls onEnded.
            .onChange(of: dragInFlight) { _, live in if !live { settleCancelledGesturesLater() } }
            .onChange(of: pinchInFlight) { _, live in if !live { settleCancelledGesturesLater() } }
            // VoiceOver: the scene is one element. In the binder, swipe
            // up/down turns pages (the same drag -> spring path a finger
            // takes); on the shelf, the rotor's actions open each binder.
            .accessibilityElement()
            .accessibilityLabel(sceneAccessibilityLabel)
            .accessibilityValue(sceneAccessibilityValue)
            .accessibilityAdjustableAction { direction in
                guard sceneMode != .shelf, let controller = model.result.controller else { return }
                let forward: Bool
                switch direction {
                case .increment: forward = true
                case .decrement: forward = false
                @unknown default: return
                }
                guard controller.flip(forward: forward) else { return }
                // The spread only advances once the spring settles, so say
                // where we're going now rather than read out where we were.
                let upcoming = controller.spreadIndex + (forward ? 1 : -1)
                AccessibilityNotification.Announcement(
                    SceneAccessibility.spreadDescription(
                        spread: upcoming, sheetCount: controller.sheetCount)
                ).post()
            }
            .accessibilityActions {
                if sceneMode == .shelf {
                    ForEach(env.binders.binders, id: \.id) { binder in
                        Button("Open \(binder.name)") { openBinderFromShelf(binder.id) }
                    }
                }
            }
        }
    }

    private var sceneAccessibilityLabel: String {
        if sceneMode == .shelf { return "Binder shelf" }
        let name = env.binders.binders.first { $0.id == env.contentBinderID }?.name
        return name.map { "\($0), open binder" } ?? "Open binder"
    }

    private var sceneAccessibilityValue: String {
        if sceneMode == .shelf {
            let count = env.binders.binders.count
            return "\(count) binder\(count == 1 ? "" : "s")"
        }
        return SceneAccessibility.spreadDescription(
            spread: spreadIndex, sheetCount: model.result.controller?.sheetCount ?? 0)
    }

    /// Stages the camera and dresses the binder for the fold we're in.
    /// Everything fold-dependent funnels through here, so there is exactly
    /// one place that decides how the scene answers the hinge.
    private func applyStage(_ newFold: FoldState, animated: Bool) {
        guard newFold.viewport.width > 0, newFold.viewport.height > 0 else { return }
        sceneFold = newFold
        model.result.cameraRig.setStage(
            BinderStage.stage(fold: newFold, viewport: newFold.viewport), animated: animated)
        let dressing = BinderStage.dressing(fold: newFold)
        BinderBuilder3D.setGutter(
            rig: model.result.binderRig,
            depth: dressing.gutterDepth,
            width: dressing.gutterWidth
        )
    }

    // MARK: Motion + gesture lifecycle

    /// Pushes Reduce Motion / Low Power into the scene and decides whether
    /// CoreMotion should be running at all: only while this view is on
    /// screen, the app is frontmost, and the foil is actually allowed to move.
    private func applyMotionPolicy() {
        let frozen = reduceMotion || lowPower
        MotionUpdateSystem.motionReduced = frozen
        // Camera and card flights answer to Reduce Motion only — Low Power
        // Mode is about the sensor stream, not about how transitions look.
        model.result.cameraRig.reduceMotion = reduceMotion
        model.result.cardInteraction?.reduceMotion = reduceMotion
        let wantsMotion = isVisible && scenePhase == .active && !frozen
        if wantsMotion {
            model.result.motionProvider.start()
        } else {
            model.result.motionProvider.stop()
        }
    }

    /// One run-loop hop later: when a gesture ends normally, onEnded and the
    /// @GestureState reset land in the same update in no documented order,
    /// and settling first would release a flick with zero velocity. After the
    /// hop, a normally-ended gesture has already reset everything and this is
    /// a no-op; a cancelled one gets cleaned up.
    private func settleCancelledGesturesLater() {
        Task { @MainActor in settleCancelledGestures() }
    }

    /// Clears whatever a gesture that never reached onEnded left behind: a
    /// pinch that still gates every other gesture, a shelf pan flag, a page
    /// hanging mid-curl with the router still tracking it, a card pinned
    /// under a finger that has gone. Every step is idempotent.
    private func settleCancelledGestures() {
        if zoomActive && !pinchInFlight {
            model.result.cameraRig.endZoom()
            zoomLevel = model.result.cameraRig.zoom
            zoomActive = false
        }
        guard !dragInFlight else { return }
        panActive = false
        model.result.router?.cancel()
        model.result.cardInteraction?.cancelDrag()
    }

    // MARK: Zoom

    /// Starts a pinch. SwiftUI will usually have handed the pinch's first
    /// finger to the DragGesture already, so settle whatever that started —
    /// a page left half-curled while the camera dollies looks broken, and the
    /// drag can't finish itself once `zoomActive` gates its callbacks.
    private func beginZoom(viewport: CGSize) {
        zoomActive = true
        if sceneMode == .shelf {
            panActive = false
        } else if model.result.cardInteraction?.isFloating == true {
            model.result.cardInteraction?.dragEnded(velocity: .zero, viewport: viewport)
        } else {
            model.result.router?.dragEnded(translation: .zero, velocity: .zero, viewport: viewport)
        }
        model.result.cameraRig.beginZoom()
    }

    /// Pinches that land within a couple of percent of 1x read as "not zoomed",
    /// so the control neither flickers on nor lingers uselessly.
    private var isZoomed: Bool { abs(zoomLevel - 1) > 0.02 }

    /// Appears only once a pinch has moved the camera: pinching back to exactly
    /// 1x by hand is fussy, and there is no other way home.
    @ViewBuilder
    private var zoomResetButton: some View {
        if isZoomed {
            Button {
                model.result.cameraRig.resetZoom()
                zoomLevel = 1
                Haptics.impact(.soft)
            } label: {
                Label(String(format: "%.1f×", zoomLevel), systemImage: "arrow.up.left.and.down.right.magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .floatingGlass()
            }
            .tint(.white)
            .accessibilityLabel("Reset zoom")
            .accessibilityValue(String(format: "%.1f times", zoomLevel))
            .accessibilityHint("Returns the camera to its default framing")
            .transition(.scale.combined(with: .opacity))
        }
    }

    // MARK: Controls (safe area)

    /// Bottom controls sit on a panel, never on the crease: in book pose they
    /// slide onto the trailing panel, and in tabletop pose they drop onto the
    /// flat lower one, which is the half your hands are resting on anyway.
    private var bottomControlOffset: CGFloat { sceneFold.trailingPanelCenterOffset }

    private var bottomControlInset: CGFloat {
        guard let tray = sceneFold.trayRect else { return 16 }
        return max(16, tray.height / 2 - 26)
    }

    private var controlsLayer: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                if sceneMode != .shelf {
                    Group {
                        shelfButton
                        Spacer()
                        if !editMode && !binderNeedsPages { shareButton }
                        editButton
                    }
                    .labelStyle(TopRowLabelStyle(iconOnly: topRowIsCompact))
                } else {
                    Spacer()
                }
            }
            Spacer()
            // Bottom-leading, not up top: the open binder's top row already
            // carries Shelf, the 3D/Grid toggle, Share and Edit, and squeezing
            // a fifth control in there collapses it to an unreadable sliver.
            HStack {
                zoomResetButton
                Spacer()
            }
            .animation(.snappy(duration: 0.2), value: isZoomed)
            .padding(.bottom, isZoomed ? 10 : 0)
            Group {
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
            .offset(x: bottomControlOffset)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: bottomControlOffset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, bottomControlInset)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { controlsWidth = $0 }
    }

    /// Shelf and Edit drop to icons when their labels would run under the
    /// floating 3D/Grid toggle. Labelled, the row needs ~430pt with the toggle
    /// centred (a 375pt iPhone SE, or iPhone Duo's outer display beside its
    /// vertical tab bar, is narrower); in book pose the toggle moves onto the
    /// leading panel and sits right where a labelled Shelf button would be.
    private var topRowIsCompact: Bool {
        controlsWidth < 430 || fold.pose == .book
    }

    private var shelfButton: some View {
        Button {
            // Send any floating card home first: parented to the scene root it
            // would otherwise keep rendering in the shelf room.
            model.result.cardInteraction?.snapFloatingCardHome()
            model.result.modeController?.enterShelf()
            sceneMode = .shelf
            floatingRef = nil
            setEditMode(false)
            zoomLevel = model.result.cameraRig.zoom   // the rig drops zoom on a scene change
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

    /// Share what you're looking at: the open spread as images, or the whole
    /// binder as a PDF.
    private var shareButton: some View {
        Menu {
            Button {
                if let controller = model.result.controller {
                    export(scope: .spread(spreadIndex: controller.spreadIndex), format: .jpegs)
                }
            } label: {
                Label("Share This Spread", systemImage: "photo.on.rectangle")
            }
            Button {
                export(scope: .all, format: .pdf)
            } label: {
                Label("Whole Binder as PDF", systemImage: "doc.richtext")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 9)
                .floatingGlass()
        }
        .tint(.white)
        .accessibilityLabel("Share")
        .accessibilityHint("Shares the open spread or the whole binder")
    }

    private func export(scope: BinderExportScope, format: BinderExportFormat) {
        guard let binderID = env.openBinderID,
              let binder = env.binders.binders.first(where: { $0.id == binderID }) else { return }
        Task {
            let ok = await exporter.run(
                binder: binder, store: env.binders, cache: env.imageCache,
                scope: scope, format: format)
            if ok {
                Haptics.success()
            } else {
                env.errors.show("Nothing to export there yet.")
            }
        }
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
        guard let pocket = picker.pick(at: point, viewport: viewport) else {
            // A miss shouldn't feel like a dead screen.
            Haptics.warning()
            return
        }
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
        // A rebuild replaces the very entity the pull-out is animating, which
        // would snap it back mid-flight. The transition refreshes at its end.
        guard !openingFromShelf, let shelf = model.result.shelfController else { return }
        shelf.refreshBinders(env.binders.binders, openBinderID: env.openBinderID)
        // Ticket taken before the await, so a slow read can't overwrite a
        // newer one that finished first.
        let request = shelf.nextDisplayRequest()
        Task {
            let contents = await env.binders.displayCaseContents()
            shelf.refreshDisplayCases(
                contents, maxCount: BinderStore.displayCaseMaxCount, requestID: request)
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
        openingFromShelf = true
        let entity = model.result.shelfController?.binderEntity(id: binderID)
        // Reduce Motion: skip the pull-and-turn; the (short) crossfade alone
        // carries the change.
        if let entity, !reduceMotion {
            var transform = entity.transform
            transform.translation += SIMD3<Float>(0, 0.015, 0.12)
            transform.rotation = simd_quatf(angle: 0.18, axis: SIMD3<Float>(0, 1, 0)) * transform.rotation
            entity.move(to: transform, relativeTo: entity.parent, duration: 0.25, timingFunction: .easeInOut)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            await env.openBinder(binderID)
            if let controller = model.result.controller {
                // CardPlacementSystem.sync indexes page.children, so a floating
                // card's pocket reads empty and rebind spawns a duplicate.
                model.result.cardInteraction?.snapFloatingCardHome()
                controller.rebind(spread: controller.sheetCount / 2)
                // Record it, so the contentBinderID observer (held off by
                // `openingFromShelf` meanwhile) doesn't rebind a second time.
                model.poolBinding.markBound(env.contentBinderID)
            }
            modeController.enterBinder()
            sceneMode = .binderOpen
            zoomLevel = model.result.cameraRig.zoom   // the rig drops zoom on a scene change
            // Once the crossfade has hidden the shelf, rebuild the row for the
            // new open binder (it decides which one stands face-out) and put
            // the pulled binder back — the reseat also covers re-opening the
            // binder that was already open, where the row doesn't change.
            try? await Task.sleep(for: .milliseconds(450))
            openingFromShelf = false
            refreshShelf()
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
                // CardPlacementSystem.sync indexes page.children, so a floating
                // card's pocket reads empty and rebind spawns a duplicate.
                model.result.cardInteraction?.snapFloatingCardHome()
                if model.poolBinding.needsRebind(for: env.contentBinderID) {
                    // The reconcile re-pointed us at another binder (the
                    // open one was deleted): start it at its middle, as
                    // any other binder switch does.
                    controller.rebind(spread: controller.sheetCount / 2)
                    model.poolBinding.markBound(env.contentBinderID)
                } else {
                    controller.rebind(spread: controller.spreadIndex)
                }
            }
        }
    }

    /// Rebinds the page pool when the content snapshot now belongs to a
    /// different binder than the one the pool last rendered. The flip
    /// controller reads the live content holder, so nothing else notices a
    /// swap: without this the pages keep showing binder A while pocket edits
    /// (addressed by `env.openBinderID`) write into binder B.
    private func syncPoolBinding() {
        // The shelf-open path rebinds (and records it) itself once its
        // content lands; stepping in mid-transition would double up.
        guard !openingFromShelf,
              model.poolBinding.needsRebind(for: env.contentBinderID),
              let controller = model.result.controller else { return }
        // Same reason as every other rebind: an out-of-pocket card would be
        // duplicated, or stranded over the wrong binder.
        model.result.cardInteraction?.snapFloatingCardHome()
        controller.rebind(spread: controller.sheetCount / 2)
        model.poolBinding.markBound(env.contentBinderID)
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
    /// Which binder the page pool last rebound against. Bookkeeping, not UI
    /// state — observing it would only re-render the view for nothing.
    @ObservationIgnored var poolBinding = PoolBinding()

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

/// Which binder's content the 3D page pool is currently rendering. The pool
/// reads a live content holder that is swapped in place, so it can't tell by
/// itself that the holder now describes a different binder; this is the
/// record every rebind path checks and updates.
nonisolated struct PoolBinding: Equatable, Sendable {
    /// nil for empty content (no binders at all) — and before the first mark.
    private(set) var binderID: String?
    private var hasBound = false

    /// True when the content now belongs to a different binder than the one
    /// last rebound — including the very first time, before anything was.
    func needsRebind(for contentBinderID: String?) -> Bool {
        !hasBound || binderID != contentBinderID
    }

    mutating func markBound(_ contentBinderID: String?) {
        binderID = contentBinderID
        hasBound = true
    }
}

/// VoiceOver wording for the 3D scene. Pure so it can be tested.
nonisolated enum SceneAccessibility {
    /// "Pages 3–4 of 10" for an open spread. The app calls a sheet a "page"
    /// everywhere else (Add Page, Remove Page 3), so this counts sheets: the
    /// spread at `spread` shows the back of sheet `spread - 1` on the left
    /// and the front of sheet `spread` on the right, and at either end only
    /// one sheet is showing.
    static func spreadDescription(spread: Int, sheetCount: Int) -> String {
        guard sheetCount > 0 else { return "No pages" }
        let s = min(max(spread, 0), sheetCount)
        if s == 0 { return "Page 1 of \(sheetCount)" }
        if s == sheetCount { return "Page \(sheetCount) of \(sheetCount), back" }
        return "Pages \(s)–\(s + 1) of \(sheetCount)"
    }
}

/// Title-and-icon normally, icon-only when the top row is short on room. The
/// title stays as the accessibility label either way.
private struct TopRowLabelStyle: LabelStyle {
    let iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            configuration.icon
        } else {
            Label(configuration)
        }
    }
}
