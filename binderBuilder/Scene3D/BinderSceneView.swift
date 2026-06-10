//
//  BinderSceneView.swift
//  binderBuilder
//
//  The single RealityView hosting the whole 3D experience (non-AR, virtual
//  camera). Scene content is assembled by SceneBootstrap from the injected
//  binder card content + texture cache, and owned by a SceneModel so the
//  deformers (which hold mesh/material state) stay alive.
//
//  Modes: on the SHELF, a tap opens the standing binder (camera dollies in).
//  In the OPEN BINDER, a drag flips pages (or spins a floating card via
//  arcball) and a tap pulls a card out / returns it. A control bar toggles a
//  floating card's owned state live; a Shelf button returns home.
//

import RealityKit
import SwiftUI

struct BinderSceneView: View {
    let env: AppEnvironment
    @State private var model: SceneModel
    @State private var sceneMode: AppMode
    /// Mirrors the floating card's ref so the toggle bar shows/hides.
    @State private var floatingRef: CardRef?
    @State private var showingLibrary = false
    @State private var debugDetail: CardSummary?
    @State private var debugScan = false

    init(env: AppEnvironment) {
        self.env = env
        let scene = SceneModel(content: env.content, textureCache: env.textureCache)
        _model = State(initialValue: scene)
        _sceneMode = State(initialValue: scene.result.modeController?.mode ?? .binderOpen)
    }

    var body: some View {
        GeometryReader { proxy in
            RealityView { content in
                content.camera = .virtual
                content.add(model.result.root)
            }
            .gesture(
                // >0 minimum so a tap never starts a page drag; the tap gesture
                // below owns pull-out/return. While a card floats, the drag
                // spins it (arcball); otherwise it curls a page.
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        guard sceneMode != .shelf else { return }
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
                        guard sceneMode != .shelf else { return }
                        let v = CGSize(width: value.velocity.width, height: value.velocity.height)
                        if model.result.cardInteraction?.isFloating == true {
                            model.result.cardInteraction?.dragEnded(velocity: v, viewport: proxy.size)
                        } else {
                            model.result.router?.dragEnded(
                                translation: value.translation, velocity: v, viewport: proxy.size
                            )
                        }
                        floatingRef = model.result.cardInteraction?.floatingRef
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
                        } else {
                            model.result.cardInteraction?.handleTap(at: value.location, viewport: proxy.size)
                        }
                        sceneMode = model.result.modeController?.mode ?? sceneMode
                        floatingRef = model.result.cardInteraction?.floatingRef
                    }
            )
        }
        .overlay(alignment: .topLeading) { shelfButton }
        .overlay(alignment: .topTrailing) { libraryButton }
        .overlay(alignment: .bottom) { ownedToggleBar }
        .sheet(isPresented: $showingLibrary) {
            LibraryView(env: env)
        }
        .sheet(item: $debugDetail) { card in
            NavigationStack { CardDetailView(card: card, env: env) }
        }
        .sheet(isPresented: $debugScan) { ScanView(env: env) }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-showScan") { debugScan = true }
            if ProcessInfo.processInfo.arguments.contains("-showLibrary") { showingLibrary = true }
            if ProcessInfo.processInfo.arguments.contains("-showCardDetail") {
                Task {
                    if let detail = try? await env.catalog?.card(id: "base1-4") {
                        debugDetail = detail.summary
                    }
                }
            }
        }
        .background(
            LinearGradient(
                colors: [Color(white: 0.22), Color(white: 0.05)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var shelfButton: some View {
        if sceneMode != .shelf {
            Button {
                model.result.modeController?.enterShelf()
                sceneMode = .shelf
                floatingRef = nil
            } label: {
                Label("Shelf", systemImage: "books.vertical.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .tint(.white)
            .padding(.leading, 16)
            .padding(.top, 12)
        }
    }

    @ViewBuilder
    private var libraryButton: some View {
        Button {
            showingLibrary = true
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .tint(.white)
        .padding(.trailing, 16)
        .padding(.top, 12)
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
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .tint(owned ? .green : .secondary)
            .padding(.bottom, 36)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

@MainActor
@Observable
final class SceneModel {
    let result: SceneBootstrapResult

    init(content: BinderCardContent?, textureCache: CardTextureCache?) {
        // An empty/absent binder falls back to the built-in debug content so
        // the scene is never blank.
        let usableContent: (any CardContentProviding)? =
            (content?.sheetCount ?? 0) > 0 ? content : nil
        result = SceneBootstrap.assemble(cardContent: usableContent, textureCache: textureCache)
    }
}
