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
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 168, ideal: 188, max: 240)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SidebarSessionStatus(model: model)
            }
        } detail: {
            switch pane ?? .subtitles {
            case .subtitles:
                SubtitleView(model: model)
            case .diagnostics:
                DiagnosticsView(model: model)
            }
        }
        .navigationTitle((pane ?? .subtitles).title)
        .frame(minWidth: 820, minHeight: 540)
    }
}

/// Persistent context at the bottom of the sidebar. It answers the two things
/// worth knowing before changing destinations: whether a session is live and
/// whether the board already contains content.
private struct SidebarSessionStatus: View {
    @Bindable var model: SubtitleModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(model.status.label)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
            }

            if !model.entries.isEmpty {
                Text(t("subtitles.entryCount", model.entries.count))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider().opacity(0.35) }
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        switch model.status {
        case .idle: return .secondary
        case .waitingForCall, .connecting: return .orange
        case .running: return .green
        case .failed: return .red
        }
    }
}

#Preview {
    ContentView(model: SubtitleModel())
}
