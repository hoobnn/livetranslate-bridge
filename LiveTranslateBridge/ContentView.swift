//
//  ContentView.swift
//  LiveTranslateBridge
//
//  Created by haobin on 2026/9/20.
//

import SwiftUI

/// The main window.
///
/// One content plane, not four layers of chrome around one.
///
/// The app has exactly two destinations and one of them is a debug panel, so
/// a permanent sidebar spent a sixth of every window on a two-item list that
/// never changes — and it put the session status, the window toolbar, the
/// control bar and the log pane on four different edges of the same screen.
/// The two destinations now live in the toolbar, where switching costs one
/// click and nothing costs width.
struct ContentView: View {
    @Bindable var model: SubtitleModel
    @State private var pane: Pane = .subtitles
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        ZStack {
            AppCanvas()

            // Keep the reading position and follow state when inspecting diagnostics.
            SubtitleView(model: model, isActive: pane == .subtitles)
                .opacity(pane == .subtitles ? 1 : 0)
                .allowsHitTesting(pane == .subtitles)
                .accessibilityHidden(pane != .subtitles)

            if pane == .diagnostics {
                DiagnosticsView(model: model)
            }
        }
        .toolbar {
            // The destination picker sits where macOS puts a view switcher:
            // in the toolbar, under the window's title, rather than taking a
            // column of its own for two items.
            ToolbarItem(placement: .navigation) {
                Picker(t("tab.subtitles"), selection: $pane) {
                    ForEach(Pane.allCases) { item in
                        Text(item.title)
                            .tag(item)
                            .accessibilityIdentifier("pane." + item.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help(t("tab.switch.help"))
            }
            ToolbarSpacer(.flexible, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label(t("ux.settings"), systemImage: "gearshape")
                }
                .help(t("ux.settings"))
            }
        }
        .navigationTitle(pane.title)
        .toolbar(removing: .title)
        .frame(minWidth: 760, minHeight: 520)
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
    }
}

#Preview {
    ContentView(model: SubtitleModel())
}
