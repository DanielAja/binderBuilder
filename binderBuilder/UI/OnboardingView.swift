//
//  OnboardingView.swift
//  binderBuilder
//
//  First-launch welcome: a short swipeable tour of the app's pillars (3D
//  binder, scanning, value tracking, drops) over the same dark gradient as
//  the launch screen, so launch -> onboarding -> app reads as one sequence.
//  Shown once; dismissing sets SettingsStore.hasSeenOnboarding.
//

import SwiftUI

struct OnboardingView: View {
    /// Called when the user finishes or skips the tour.
    let onFinish: () -> Void

    @State private var page = 0

    private struct Page {
        let icon: String
        let title: String
        let message: String
        let tint: Color
    }

    private static let pages: [Page] = [
        Page(
            icon: "book.fill",
            title: "Welcome to Binder Builder",
            message: "Your card collection in a living 3D binder — flip pages, pull out cards, and watch foils shimmer as you tilt your phone.",
            tint: .orange),
        Page(
            icon: "camera.viewfinder",
            title: "Scan Cards In",
            message: "Point the camera at a card to identify it instantly, or photograph a whole binder page and add all nine pockets at once.",
            tint: .teal),
        Page(
            icon: "chart.line.uptrend.xyaxis",
            title: "Track Your Value",
            message: "Live market prices for every card you own, set completion at a glance, and a trade log that keeps both sides honest.",
            tint: .green),
        Page(
            icon: "calendar.badge.clock",
            title: "Never Miss a Drop",
            message: "A release calendar with reminders, and alerts when a set you're waiting on lands at a store near you.",
            tint: .pink),
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.22), Color(white: 0.05)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    if page < Self.pages.count - 1 {
                        Button("Skip") { onFinish() }
                            .foregroundStyle(.white.opacity(0.6))
                            .padding()
                    }
                }
                .frame(height: 52)

                TabView(selection: $page) {
                    ForEach(Array(Self.pages.enumerated()), id: \.offset) { index, card in
                        VStack(spacing: 24) {
                            Image(systemName: card.icon)
                                .font(.system(size: 88))
                                .foregroundStyle(card.tint)
                                .tiltShimmer()
                                .accessibilityHidden(true)
                            Text(card.title)
                                .font(.title.bold())
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                            Text(card.message)
                                .font(.body)
                                .foregroundStyle(.white.opacity(0.75))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                        .tag(index)
                        .padding(.bottom, 48) // clear the page dots
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))

                Button {
                    if page < Self.pages.count - 1 {
                        withAnimation { page += 1 }
                    } else {
                        onFinish()
                    }
                } label: {
                    Text(page < Self.pages.count - 1 ? "Continue" : "Get Started")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
            }
        }
    }
}

#Preview {
    OnboardingView {}
}
