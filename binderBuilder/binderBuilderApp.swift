//
//  binderBuilderApp.swift
//  binderBuilder
//
//  Created by Daniel on 6/9/26.
//

import SwiftUI

@main
struct binderBuilderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                // Publishes the device's fold (hinge angle + crease position)
                // to the whole app. FoldState.none on hardware that doesn't
                // fold, which is every iPhone before the Duo.
                .foldAware()
        }
    }
}
