//
//  LiveTranslateBridgeApp.swift
//  LiveTranslateBridge
//
//  Created by haobin on 2026/9/20.
//

import SwiftUI

@main
struct LiveTranslateBridgeApp: App {
    /// One model for the whole app: the subtitle board and the settings pane
    /// edit the same translation options.
    @State private var model = SubtitleModel()

    /// The interface language. A singleton because the Settings scene is a
    /// separate window with no ancestor in common with the main one, and both
    /// have to relabel together when the language changes.
    @State private var localization = LocalizationStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .localized(localization)
                // A board with entries on it needs credentials and a live
                // call, which makes the subtitle layout the one part of the
                // app that cannot be looked at on demand. `-sampleBoard` fills
                // it with a sample exchange so it can be — for a screenshot,
                // or to check a layout change at a real window size.
                #if DEBUG
                .task {
                    guard ProcessInfo.processInfo.arguments.contains("-sampleBoard")
                    else { return }
                    model.seedSampleBoard()
                }
                #endif
        }
        .defaultSize(width: 860, height: 600)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView(model: model, localization: localization)
                .localized(localization)
        }
    }
}
