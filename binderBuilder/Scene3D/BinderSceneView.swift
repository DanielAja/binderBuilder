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
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        model.result.router?.dragChanged(
                            location: value.location,
                            startLocation: value.startLocation,
                            translation: value.translation,
                            viewport: proxy.size
                        )
                    }
                    .onEnded { value in
                        model.result.router?.dragEnded(
                            translation: value.translation,
                            velocity: CGSize(width: value.velocity.width, height: value.velocity.height),
                            viewport: proxy.size
                        )
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
