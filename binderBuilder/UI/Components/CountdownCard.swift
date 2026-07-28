//
//  CountdownCard.swift
//  binderBuilder
//
//  Compact, reusable row for one upcoming release: name + series, the big
//  days-to-go number (a motion-driven tiltShimmer sheen — it self-gates under
//  Reduce Motion), an "Expected" badge + source footnote for dates that
//  aren't TCGdex-confirmed yet, and a per-release reminder bell.
//

import SwiftUI

struct CountdownCard: View {
    let release: UpcomingRelease
    let isSubscribed: Bool
    let onToggleSubscribed: () -> Void

    /// Whole calendar days from today to the release day; can go negative if
    /// the date has already passed and the calendar hasn't refreshed.
    private var daysRemaining: Int {
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: Date()),
            to: calendar.startOfDay(for: release.expectedDate)
        ).day ?? 0
    }

    /// Only a `.confirmed` date is treated as firm — `.expected`/`.rumored`
    /// both get the badge + footnote (mirrors DropScheduler's own hedge).
    private var isFirmDate: Bool { release.confidence == .confirmed }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(release.name).font(.headline)
                    if !isFirmDate {
                        Text("Expected")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.orange.opacity(0.16), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                Text(release.seriesName).font(.subheadline).foregroundStyle(.secondary)
                Text(release.expectedDate.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(.secondary)
                if !isFirmDate {
                    Text(release.sourceNote)
                        .font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            VStack(spacing: 0) {
                Text("\(max(daysRemaining, 0))")
                    .font(.title2.bold().monospacedDigit())
                    .tiltShimmer()
                Text(daysRemaining == 1 ? "day" : "days")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(max(daysRemaining, 0)) \(daysRemaining == 1 ? "day" : "days") to go")

            Button {
                Haptics.selection()
                onToggleSubscribed()
            } label: {
                Image(systemName: isSubscribed ? "bell.fill" : "bell")
                    .imageScale(.large)
                    .foregroundStyle(isSubscribed ? .orange : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSubscribed
                ? "Reminders on for \(release.name)"
                : "Reminders off for \(release.name)")
        }
        .padding(.vertical, 4)
    }
}
