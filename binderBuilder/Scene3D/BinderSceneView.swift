//
//  BinderSceneView.swift
//  binderBuilder
//
//  The single RealityView hosting the whole 3D experience (non-AR, virtual
//  camera). Scene content is assembled by SceneBootstrap from the injected
//  binder card content + texture cache, and owned by a SceneModel so the
//  deformers (which hold mesh/material state) stay alive.
//
//  Gestures: a drag flips pages (or, while a card floats, spins it via
//  arcball); a spatial tap pulls a card out or returns it. A small control
//  bar appears while a card floats to toggle its owned state live
//  (color <-> grayscale) — a temporary stand-in for the full collection UI.
//

import RealityKit
import SwiftUI

struct BinderSceneView: View {
    let env: AppEnvironment
    @State private var model: SceneModel
    /// Mirrors the floating card's ref so the toggle bar shows/hides.
    @State private var floatingRef: CardRef?

    init(env: AppEnvironment) {
        self.env = env
        _model = State(initialValue: SceneModel(content: env.content, textureCache: env.textureCache))
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
                        model.result.cardInteraction?.handleTap(at: value.location, viewport: proxy.size)
                        floatingRef = model.result.cardInteraction?.floatingRef
                    }
            )
        }
        .overlay(alignment: .bottom) { ownedToggleBar }
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
