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
        if ProcessInfo.processInfo.arguments.contains("-showSets") {
            _tab = State(initialValue: .browse)
        } else if ProcessInfo.processInfo.arguments.contains("-showCollection") {
            _tab = State(initialValue: .collection)
        } else {
            switch DebugLaunchState.current.uiState {
            case .binderOpen, .cardFloating: _tab = State(initialValue: .binder)
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

            BinderSceneView(env: env)
                .tabItem { Label("Binder", systemImage: "book.fill") }
                .tag(RootTab.binder)

            CollectionView(env: env)
                .tabItem { Label("Collection", systemImage: "square.stack.3d.up.fill") }
                .tag(RootTab.collection)

            NavigationStack { SettingsView(env: env) }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(RootTab.settings)
        }
    }
}
