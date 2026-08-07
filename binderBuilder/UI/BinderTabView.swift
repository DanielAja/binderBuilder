//
//  BinderTabView.swift
//  binderBuilder
//
//  The Binder tab's host: the 3D scene and the 2D grid editor over the same
//  open binder, switched by a segmented 3D | Grid control. The SceneModel is
//  cached in AppEnvironment, so leaving the 3D side doesn't tear it down.
//

import SwiftUI

struct BinderTabView: View {
    let env: AppEnvironment
    @State private var showGrid = false

    var body: some View {
        ZStack(alignment: .top) {
            if showGrid, let binderID = env.openBinderID {
                NavigationStack {
                    Binder2DView(env: env, binderID: binderID, showGrid: $showGrid)
                }
                .id(binderID)   // rebuild the editor if the open binder changes
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                BinderSceneView(env: env)
                    .id(env.sceneGeneration)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .overlay(alignment: .top) { floatingToggle }
            }
        }
        .animation(.easeInOut(duration: 0.22), value: showGrid)
    }

    /// The 3D-side switch, floating center-top between the scene's Shelf and
    /// Edit buttons. (The grid side renders its twin in the toolbar.)
    @ViewBuilder
    private var floatingToggle: some View {
        if env.openBinderID != nil {
            Picker("View", selection: $showGrid) {
                Text("3D").tag(false)
                Text("Grid").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 130)
            .padding(.top, 8)
            .accessibilityLabel("Binder view style")
        }
    }
}
