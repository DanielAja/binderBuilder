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
    @State private var showingOnboarding = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if env.isReady {
                RootTabView(env: env)
                    .onAppear { showingOnboarding = shouldShowOnboarding }
                    .fullScreenCover(isPresented: $showingOnboarding) {
                        OnboardingView {
                            env.settings.hasSeenOnboarding = true
                            showingOnboarding = false
                        }
                    }
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
        .overlay(alignment: .top) { errorBanner }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: env.errors.banner)
        .onChange(of: scenePhase) { _, phase in
            guard env.isReady else { return }
            if phase == .active { Task { await env.runAlertChecks() } }
            if phase == .background, env.settings.icloudSyncEnabled { Task { await env.cloud.push() } }
        }
        .task {
            #if DEBUG
            // Smoke test: -fireTestAlert requests notifications + fires one.
            if ProcessInfo.processInfo.arguments.contains("-fireTestAlert") {
                await NotificationService.requestAuthorization()
                NotificationService.fire(title: "Binder Builder", body: "Price alerts are working ✅")
            }
            #endif
        }
    }

    /// First launch only — and never over a debug/screenshot run that routes
    /// straight to a specific tab (tools/verify.sh flows must stay uncovered).
    private var shouldShowOnboarding: Bool {
        guard !env.settings.hasSeenOnboarding else { return false }
        if DebugLaunchState.current.uiState != nil { return false }
        let routingFlags = ["-showSets", "-showCollection", "-showSettings",
                            "-showDrops", "-showCardDetail", "-showScan", "-fireTestAlert"]
        if routingFlags.contains(where: { DebugLaunchState.launchFlag($0) }) { return false }
        return true
    }

    @ViewBuilder private var errorBanner: some View {
        if let banner = env.errors.banner {
            Text(banner.message)
                .font(.subheadline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(banner.isError ? Color.red : Color.accentColor,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(radius: 8, y: 2)
                .padding(.horizontal)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { env.errors.dismiss() }
                .accessibilityAddTraits(.isStaticText)
                .accessibilityHint("Double-tap to dismiss")
        }
    }
}

#Preview {
    ContentView()
}
