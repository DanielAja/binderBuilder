//
//  RootTabView.swift
//  binderBuilder
//
//  The app shell: Home dashboard, Browse (search + sets), the 3D Binder hero,
//  Collection (owned cards + wishlist), and Settings. The 3D SceneModel is
//  owned by AppEnvironment so the Binder tab stays mounted/alive across tab
//  switches (no re-init cost).
//

import SwiftUI

enum RootTab: Hashable {
    case home, browse, binder, collection, settings
}

struct RootTabView: View {
    let env: AppEnvironment
    @State private var tab: RootTab

    init(env: AppEnvironment) {
        self.env = env
        // Debug/deep-link: -uiState binderOpen|cardFloating opens the Binder tab.
        if DebugLaunchState.launchFlag("-showSets") {
            _tab = State(initialValue: .browse)
        } else if DebugLaunchState.launchFlag("-showCollection") {
            _tab = State(initialValue: .collection)
        } else if DebugLaunchState.launchFlag("-showSettings") || DebugLaunchState.launchFlag("-showDrops") {
            // -showDrops routes here too; SettingsView presents DropsView as
            // a sheet once this tab loads (see its own showingDrops flag).
            _tab = State(initialValue: .settings)
        } else if DebugLaunchState.launchFlag("-showCardDetail") || DebugLaunchState.launchFlag("-showScan") {
            // Both flags are handled inside BinderSceneView.onAppear, which
            // never mounts unless the Binder tab is the initial selection.
            _tab = State(initialValue: .binder)
        } else {
            switch DebugLaunchState.current.uiState {
            case .binderOpen, .cardFloating, .shelf: _tab = State(initialValue: .binder)
            default: _tab = State(initialValue: .home)
            }
        }
    }

    var body: some View {
        TabView(selection: $tab) {
            HomeView(env: env, selectedTab: $tab)
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(RootTab.home)

            BrowseView(env: env)
                .tabItem { Label("Browse", systemImage: "magnifyingglass") }
                .tag(RootTab.browse)

            // Keyed on sceneGeneration: sorting the open binder re-snapshots
            // its content, and the new identity rebuilds the scene from it.
            BinderSceneView(env: env)
                .id(env.sceneGeneration)
                .tabItem { Label("Binder", systemImage: "book.fill") }
                .tag(RootTab.binder)

            CollectionView(env: env)
                .tabItem { Label("Collection", systemImage: "square.stack.3d.up.fill") }
                .tag(RootTab.collection)

            NavigationStack { SettingsView(env: env) }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(RootTab.settings)
        }
        .minimizingTabBar()
    }
}
