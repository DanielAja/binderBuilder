//
//  BinderSceneView.swift
//  binderBuilder
//
//  The single RealityView hosting the whole 3D experience (non-AR, virtual
//  camera). Scene content is assembled by SceneBootstrap and owned by a
//  SceneModel so deformers (which hold mesh/material state) stay alive.
//

import RealityKit
import SwiftUI

struct BinderSceneView: View {
    @State private var model = SceneModel()

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            content.add(model.result.root)
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
