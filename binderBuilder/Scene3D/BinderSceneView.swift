//
//  BinderSceneView.swift
//  binderBuilder
//
//  The single RealityView hosting the whole 3D experience (non-AR, virtual
//  camera). Scene content is assembled by SceneBootstrap and owned by a
//  SceneModel so deformers (which hold mesh/material state) stay alive.
//  A DragGesture(minimumDistance: 0) feeds GestureRouter: touch-down picks a
//  page via the camera ray, horizontal dragging curls it, release springs it.
//

import RealityKit
import SwiftUI

struct BinderSceneView: View {
    @State private var model = SceneModel()

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
                    }
            )
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        model.result.cardInteraction?.handleTap(at: value.location, viewport: proxy.size)
                    }
            )
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
}

@MainActor
@Observable
final class SceneModel {
    let result: SceneBootstrapResult

    init() {
        result = SceneBootstrap.assemble()
    }
}

#Preview {
    BinderSceneView()
}
