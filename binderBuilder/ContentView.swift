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
    @Environment(\.scenePhase) private var scenePhase

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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, env.isReady { Task { await env.runAlertChecks() } }
        }
        .task {
            // Smoke test: -fireTestAlert requests notifications + fires one.
            if ProcessInfo.processInfo.arguments.contains("-fireTestAlert") {
                await NotificationService.requestAuthorization()
                NotificationService.fire(title: "Binder Builder", body: "Price alerts are working ✅")
            }
        }
    }
}

#Preview {
    ContentView()
}
