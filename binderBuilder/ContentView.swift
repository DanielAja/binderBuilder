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
    @Environment(\.fold) private var fold

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
            // Guarded push (never from the temporary DB, never over a newer
            // cloud copy) under a background-task assertion so it can finish.
            if phase == .background, env.settings.icloudSyncEnabled { env.cloud.pushInBackground() }
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
        // Keep in step with every flag that routes somewhere: a missing entry
        // means that screenshot run comes back showing the onboarding tour.
        let routingFlags = ["-showSets", "-showCollection", "-showSettings",
                            "-showDrops", "-showCardDetail", "-showScan", "-fireTestAlert",
                            "-showGrid", "-showTrade", "-showFastScan",
                            "-fastScanDemo", "-tradeEditorDemo"]
        if routingFlags.contains(where: { DebugLaunchState.launchFlag($0) }) { return false }
        return true
    }

    /// Width of the panel the error banner is confined to in book pose;
    /// `nil` (unconstrained, full width) everywhere else.
    private var bannerPanelWidth: CGFloat? {
        guard fold.pose == .book, fold.viewport.width > 0 else { return nil }
        return max(200, fold.creaseFraction * fold.viewport.width - 32)
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
                // In book pose a full-width banner would be creased down the
                // middle, so it sits on the leading panel instead.
                .frame(maxWidth: bannerPanelWidth)
                .offset(x: fold.leadingPanelCenterOffset)
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
