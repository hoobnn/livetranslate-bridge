import SwiftUI

/// What the subtitle board lets the menu bar do to it.
///
/// Copying and clearing carry state the board owns — the "Copied" feedback,
/// the confirmation dialog, whether the board is following the newest line —
/// so the menu calls back into the board instead of reaching into the model
/// and leaving the board's own feedback out of step with what happened.
struct SubtitleActions {
    var canEdit: Bool
    var isFollowingLatest: Bool
    var copyAll: () -> Void
    var requestClear: () -> Void
    var jumpToLatest: () -> Void
    var showSetup: () -> Void
    var showAudioRouting: () -> Void
}

extension FocusedValues {
    /// Published by the subtitle board while it is the visible pane.
    @Entry var subtitleActions: SubtitleActions?
    /// The main window's pane, so the View menu can switch it.
    @Entry var mainPane: Binding<ContentView.Pane>?
    /// Exports whatever session the visible pane is showing — the live board,
    /// or the one selected in the history. Nil when there is nothing to export.
    @Entry var exportSession: ExportAction?
}

/// "Export as Document…" for whichever pane published it.
///
/// Compared by `key` rather than by the closure, which cannot be compared at
/// all: without it every redraw of the pane would look like a new value and
/// invalidate the menu bar.
struct ExportAction: Equatable {
    let key: String
    let perform: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
}

/// The menu bar.
///
/// macOS expects every toolbar action to be findable in the menu bar too —
/// that is where people look for a command and learn its shortcut, and where
/// keyboard and accessibility users reach it without hunting for a button.
/// Each shortcut is bound here and only here, so a key never has two owners.
///
/// Items are text only: macOS 27 hides menu item icons unless a group
/// consistently uses them, and verbs read better without one.
struct AppCommands: Commands {
    let model: SubtitleModel
    let updater: AppUpdater

    @FocusedValue(\.subtitleActions) private var actions
    @FocusedValue(\.mainPane) private var pane
    @FocusedValue(\.exportSession) private var exportSession

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(t("menu.checkForUpdates")) { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }

        CommandGroup(replacing: .importExport) {
            Button(t("export.menu")) { exportSession?.perform() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(exportSession == nil)
        }

        CommandGroup(after: .pasteboard) {
            Section {
                Button(t("subtitles.copyAll")) { actions?.copyAll() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(actions?.canEdit != true)
                Button(t("menu.clear")) { actions?.requestClear() }
                    .disabled(actions?.canEdit != true)
            }
        }

        CommandGroup(before: .toolbar) {
            Section {
                ForEach(Array(ContentView.Pane.allCases.enumerated()), id: \.element) {
                    index, item in
                    Toggle(item.title, isOn: Binding(
                        get: { pane?.wrappedValue == item },
                        set: { if $0 { pane?.wrappedValue = item } }
                    ))
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")),
                                      modifiers: .command)
                    .disabled(pane == nil)
                }
            }

            Section {
                Button(t("menu.textBigger")) { model.transcriptSize = model.transcriptSize.larger }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(model.transcriptSize == .extraLarge)
                Button(t("menu.textSmaller")) { model.transcriptSize = model.transcriptSize.smaller }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(model.transcriptSize == .small)
                Button(t("menu.textDefault")) { model.transcriptSize = .medium }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(model.transcriptSize == .medium)
            }

            Section {
                Toggle(t("display.timestamps"), isOn: Binding(
                    get: { model.showsTimestamps }, set: { model.showsTimestamps = $0 }
                ))
                Toggle(t("display.sourceText"), isOn: Binding(
                    get: { model.showsSourceText }, set: { model.showsSourceText = $0 }
                ))
                .disabled(model.runningMode == .transcribe)
            }

            Section {
                Button(t("subtitles.jumpToLatest")) { actions?.jumpToLatest() }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    .disabled(actions == nil || actions?.isFollowingLatest == true)
            }
        }

        CommandMenu(t("menu.session")) {
            Button(model.isRunning ? t("menu.session.stop") : t("menu.session.start")) {
                if model.isRunning { model.stop() } else { model.start() }
            }
            .keyboardShortcut(.return, modifiers: .command)

            Button(t("audio.skipSpeech")) { model.interruptTranslation() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!model.isRunning || model.mode != .translate)

            Divider()

            Button(t("menu.session.setup")) { actions?.showSetup() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Button(t("menu.session.audio")) { actions?.showAudioRouting() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }
    }
}

extension SubtitleModel.TranscriptSize {
    /// One step up the scale, stopping at the largest.
    var larger: Self {
        let all = Self.allCases
        let index = all.firstIndex(of: self)!
        return all[min(index + 1, all.count - 1)]
    }

    /// One step down the scale, stopping at the smallest.
    var smaller: Self {
        let all = Self.allCases
        let index = all.firstIndex(of: self)!
        return all[max(index - 1, 0)]
    }
}
