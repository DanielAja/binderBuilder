//
//  AppMode.swift
//  binderBuilder
//
//  Top-level application mode. The 3D scene and 2D chrome both key off this.
//

nonisolated enum AppMode: String, Codable, Sendable, CaseIterable {
    case shelf
    case binderOpen
    case cardFloating
}

extension AppMode {
    /// Maps the `-uiState` launch argument onto an app mode.
    init(uiState: DebugLaunchState.UIState) {
        switch uiState {
        case .shelf: self = .shelf
        case .binderOpen: self = .binderOpen
        case .cardFloating: self = .cardFloating
        }
    }
}
