//
//  ContentView.swift
//  LiveTranslateBridge
//
//  Created by haobin on 2026/9/20.
//

import SwiftUI

struct ContentView: View {
    @Bindable var model: SubtitleModel
    @State private var pane: Pane? = .subtitles
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    /// Neither `Tab` nor `Section`: both name SwiftUI types used right below.
    enum Pane: String, Hashable, CaseIterable, Identifiable {
        case subtitles
        case diagnostics

        var id: String { rawValue }

        @MainActor
        var title: String { t("tab.\(rawValue)") }

        var systemImage: String {
            switch self {
            case .subtitles: return "captions.bubble"
            case .diagnostics: return "waveform.badge.magnifyingglass"
            }
        }
    }

    var body: some View {
        // A sidebar rather than a tab bar: macOS 26 gives the split view's
        // sidebar its own glass layer under the content, and the two panes
        // are destinations, not peers a user flips between mid-call.
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(Pane.allCases, selection: $pane) { item in
                NavigationLink(value: item) {
                    Label(item.title, systemImage: item.systemImage)
                }
            }
            .navigationSplitViewColumnWidth(min: 168, ideal: 188, max: 240)
        } detail: {
            switch pane ?? .subtitles {
            case .subtitles:
                SubtitleView(model: model)
            case .diagnostics:
                DiagnosticsView(model: model)
            }
        }
        .navigationTitle(t("app.name"))
        .frame(minWidth: 720, minHeight: 480)
    }
}

#Preview {
    ContentView(model: SubtitleModel())
}
