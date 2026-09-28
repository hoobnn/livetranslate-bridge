import AppKit
import SwiftUI

/// Past sessions: a list on the leading side, the selected transcript beside
/// it, set exactly as the board set it live.
///
/// Read-only on purpose. A transcript is a record of what was said, and the
/// only edits worth offering on one are keeping it somewhere else (export,
/// copy) or not keeping it at all (delete).
struct HistoryView: View {
    let model: SubtitleModel
    let history: SessionHistory

    @State private var selection: SessionRecord.ID?
    @State private var query = ""
    @State private var pendingDeletion: SessionRecord.ID?
    @State private var didCopy = false
    @State private var copyFeedbackTask: Task<Void, Never>?

    private var filtered: [SessionRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return history.records }
        return history.records.filter { record in
            record.turns.contains {
                $0.transcript.localizedStandardContains(needle)
                    || $0.translation.localizedStandardContains(needle)
            }
        }
    }

    private var selected: SessionRecord? {
        selection.flatMap(history.record(id:))
    }

    var body: some View {
        Group {
            if history.isLoaded && history.records.isEmpty {
                ContentUnavailableView {
                    Label(t("history.empty.title"), systemImage: "clock")
                } description: {
                    Text(model.savesHistory
                         ? t("history.empty.message") : t("history.disabled.message"))
                }
            } else {
                HStack(spacing: 0) {
                    sessionList
                        .frame(width: 290)
                    Divider()
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .toolbar { toolbarItems }
        .focusedSceneValue(\.exportSession, selected.map { record in
            ExportAction(key: "\(record.id)-\(record.endedAt.timeIntervalSince1970)") {
                ExportPanel.present(record)
            }
        })
        .confirmationDialog(t("history.delete.title"),
                            isPresented: Binding(
                                get: { pendingDeletion != nil },
                                set: { if !$0 { pendingDeletion = nil } }),
                            titleVisibility: .visible) {
            Button(t("history.delete"), role: .destructive) {
                if let id = pendingDeletion { delete(id) }
            }
            Button(t("ux.cancel"), role: .cancel) { }
        } message: {
            Text(t("history.delete.message"))
        }
        .onAppear {
            if selection == nil { selection = history.records.first?.id }
        }
        .onChange(of: history.records.first?.id) { _, first in
            if selection == nil { selection = first }
        }
        .onDisappear { copyFeedbackTask?.cancel() }
    }

    // MARK: - list

    private var sessionList: some View {
        VStack(spacing: 0) {
            TextField(t("history.search"), text: $query,
                      prompt: Text(t("history.search")))
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, Theme.spacing12)
                .padding(.vertical, Theme.spacing8)
                .accessibilityIdentifier("history.search")

            List(selection: $selection) {
                ForEach(filtered) { record in
                    HistoryRow(record: record, isLive: isLive(record))
                        .tag(record.id)
                        .contextMenu { rowMenu(record) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onDeleteCommand {
                if let selected, !isLive(selected) { pendingDeletion = selected.id }
            }
            .overlay {
                if !query.isEmpty && filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ record: SessionRecord) -> some View {
        Button(t("export.menu")) { ExportPanel.present(record) }
        Button(t("subtitles.copyAll")) { copy(record) }
        Divider()
        Button(t("history.delete"), role: .destructive) { pendingDeletion = record.id }
            .disabled(isLive(record))
    }

    // MARK: - detail

    @ViewBuilder
    private var detail: some View {
        if let selected {
            HistoryTranscript(record: selected, model: model)
        } else {
            ContentUnavailableView(t("history.select"), systemImage: "text.bubble")
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarSpacer(.flexible, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                if let selected { copy(selected) }
            } label: {
                Label(t(didCopy ? "ux.copied" : "subtitles.copyAll"),
                      systemImage: didCopy ? "checkmark" : "document.on.document")
            }
            .disabled(selected == nil)
            .help(t(didCopy ? "ux.copied" : "subtitles.copyAll"))
            .contentTransition(.symbolEffect(.replace))

            Button {
                if let selected { ExportPanel.present(selected) }
            } label: {
                Label(t("export.menu"), systemImage: "square.and.arrow.up")
            }
            .disabled(selected == nil)
            .help(t("export.help") + " (⇧⌘E)")
            .accessibilityIdentifier("history.export")

            Button {
                pendingDeletion = selected?.id
            } label: {
                Label(t("history.delete"), systemImage: "trash")
            }
            .disabled(selected.map(isLive) ?? true)
            .help(t("history.delete"))
            .accessibilityIdentifier("history.delete")
        }
    }

    // MARK: - actions

    /// The session still being written to. It shows in the list so the
    /// current call can be reread from here, but it cannot be deleted: the
    /// next autosave would only bring it back.
    private func isLive(_ record: SessionRecord) -> Bool {
        model.isRunning && record.id == model.liveSessionID
    }

    private func delete(_ id: SessionRecord.ID) {
        let ids = filtered.map(\.id)
        let next = ids.firstIndex(of: id).flatMap { index in
            ids.indices.contains(index + 1) ? ids[index + 1]
                : index > 0 ? ids[index - 1] : nil
        }
        history.delete(id)
        if selection == id { selection = next }
        pendingDeletion = nil
    }

    private func copy(_ record: SessionRecord) {
        let board = NSPasteboard.general
        board.clearContents()
        guard board.setString(SessionExport.plainText(record), forType: .string) else { return }
        didCopy = true
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }
}

// MARK: - row

private struct HistoryRow: View {
    let record: SessionRecord
    let isLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Theme.spacing6) {
                Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.App.label)
                    .lineLimit(1)
                if isLive {
                    Circle().fill(Theme.live).frame(width: 6, height: 6)
                        .help(t("history.live"))
                        .accessibilityLabel(t("history.live"))
                }
            }
            Text("\(SessionExport.languagePair(record)) · \(record.mode.label)")
                .font(.App.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(t("subtitles.entryCount", record.turns.count)
                 + " · " + SessionExport.durationLabel(record.duration))
                .font(.App.numeric)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            if let preview {
                Text(preview)
                    .font(.App.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    /// The first thing that was said, which is usually how someone finds the
    /// call they are looking for faster than by its date.
    private var preview: String? {
        guard let first = record.turns.first else { return nil }
        let text = record.mode == .translate && !first.translation.isEmpty
            ? first.translation : first.transcript
        return text.isEmpty ? nil : text
    }
}

// MARK: - transcript

/// One saved session, set as the board would have set it.
private struct HistoryTranscript: View {
    let record: SessionRecord
    let model: SubtitleModel

    @State private var rows: [SubtitleModel.VisibleEntry] = []

    var body: some View {
        GeometryReader { geometry in
            let board = min(geometry.size.width, Theme.boardMaxWidth)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.spacing8) {
                    header
                        .padding(.bottom, Theme.spacing12)
                    ForEach(rows) { row in
                        EntryCard(
                            entry: row.entry,
                            showsTranslation: record.mode == .translate,
                            size: model.transcriptSize,
                            showsTime: model.showsTimestamps,
                            showsSource: model.showsSourceText,
                            continuesRun: row.continuesRun,
                            measure: Theme.transcriptMeasure(for: model.transcriptSize.primary)
                        )
                        .padding(.top, row.startsNewSpeaker ? Theme.spacing16 : 0)
                    }
                }
                .padding(.horizontal, Theme.gutter(boardWidth: board))
                .padding(.vertical, Theme.spacing20)
                .frame(maxWidth: Theme.boardMaxWidth, alignment: .center)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollContentBackground(.hidden)
        }
        // Rebuilt when the session changes, or when the live one is saved
        // again with more on it — not on every redraw, since each row is an
        // observable object and rebuilding them would re-identify every card.
        .task(id: record.id) { rebuild() }
        .onChange(of: record.endedAt) { _, _ in rebuild() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.spacing4) {
            Text(SessionExport.title(record))
                .font(.App.title)
                .textSelection(.enabled)
            Text([SessionExport.timeRange(record),
                  SessionExport.languagePair(record),
                  record.mode.label,
                  record.scope.label].joined(separator: " · "))
                .font(.App.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func rebuild() {
        var built: [SubtitleModel.VisibleEntry] = []
        var previous: SubtitleModel.Direction?
        for turn in record.turns {
            let entry = SubtitleModel.Entry(
                direction: turn.direction,
                transcript: turn.transcript,
                translation: turn.translation,
                isComplete: true,
                startedAt: turn.startedAt
            )
            built.append(SubtitleModel.VisibleEntry(
                entry: entry,
                continuesRun: previous == turn.direction,
                startsNewSpeaker: previous != nil && previous != turn.direction
            ))
            previous = turn.direction
        }
        rows = built
    }
}
