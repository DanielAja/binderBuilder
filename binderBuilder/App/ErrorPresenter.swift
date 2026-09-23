//
//  ErrorPresenter.swift
//  binderBuilder
//
//  A tiny, app-wide surface for user-facing problems that were previously
//  swallowed (backup import/restore, iCloud sync, scan, a degraded launch).
//  A root overlay observes `banner`; messages auto-dismiss.
//

import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class ErrorPresenter {
    struct Banner: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let isError: Bool
    }

    private(set) var banner: Banner?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    /// Shows a transient message. `isError` tints it (red) vs a neutral note.
    func show(_ message: String, isError: Bool = true) {
        banner = Banner(message: message, isError: isError)
        // The banner appears at the top without taking focus, so VoiceOver
        // users would never hear it (and it auto-dismisses in 3.5 s).
        UIAccessibility.post(notification: .announcement, argument: message)
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            if !Task.isCancelled { self?.banner = nil }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        banner = nil
    }
}
