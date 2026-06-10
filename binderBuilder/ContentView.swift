//
//  ContentView.swift
//  binderBuilder
//
//  Root view: owns the AppEnvironment, prepares first-run content (demo seed +
//  binder snapshot), and shows the 3D binder once ready.
//

import SwiftUI

struct ContentView: View {
    @State private var env = AppEnvironment()

    var body: some View {
        ZStack {
            if env.isReady {
                RootTabView(env: env)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [Color(white: 0.22), Color(white: 0.05)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .ignoresSafeArea()
                    ProgressView("Preparing your binder…")
                        .tint(.white)
                        .foregroundStyle(.white)
                }
                .task { await env.prepare() }
            }
        }
    }
}

#Preview {
    ContentView()
}
