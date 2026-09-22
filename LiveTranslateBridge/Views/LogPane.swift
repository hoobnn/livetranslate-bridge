import SwiftUI

/// The live log, docked under the subtitle board.
///
/// The chain behind the subtitles crosses three threads, and when it breaks
/// the board just stays empty. This is the same trace the unified log carries,
/// in the window — so a stalled call can be read without leaving the app for
/// `log stream`.
struct LogPane: View {
    @Bindable var model: LogModel
    @Binding var isExpanded: Bool

    /// Whether new lines still pull the view down. Cleared the moment the
    /// reader scrolls away, restored when they come back to the bottom.
    @State private var isFollowingTail = true

    /// Tall enough for a dozen lines, short enough to leave the subtitles the
    /// larger half of the window.
    private static let contentHeight: CGFloat = 176

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                Divider().opacity(0.4)
                lineList
                    .frame(height: Self.contentHeight)
            }
        }
        .background(.background.opacity(isExpanded ? 0.9 : 0), in:
            RoundedRectangle(cornerRadius: 12))
        .animation(Theme.settle, value: isExpanded)
        // Closing the pane ends the reading session that scrolled away from
        // the tail; reopening it should land on the newest line rather than
        // wherever a failure was being read an hour ago.
        .onChange(of: isExpanded) { _, expanded in
            if !expanded { isFollowingTail = true }
        }
    }

    // MARK: - header

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(Theme.settle) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Label(t("log.title"), systemImage: "list.bullet.rectangle")
                        .font(.App.label)
                        .labelStyle(.titleAndIcon)
                }
            }
            .buttonStyle(.plain)
            .help(t("log.toggle.help"))
            // The chevron says open or closed visually; `isExpanded` is what
            // says it to VoiceOver, which otherwise announces the same
            // "Log" button in both states.
            .accessibilityLabel(t("log.title"))
            .accessibilityAddTraits(isExpanded ? [.isButton, .isSelected] : .isButton)

            Spacer(minLength: 8)

            if isExpanded {
                categoryChips
                levelPicker
            }

            if isExpanded {
            Text(t("log.lineCount", model.lines.count))
                .font(.App.numeric)
                .foregroundStyle(.tertiary)

            controls
            }
        }
        .padding(.horizontal, Theme.spacing16)
        .padding(.vertical, Theme.spacing8)
        .contentShape(.rect)
    }

    private var categoryChips: some View {
        HStack(spacing: 4) {
            ForEach(LogCategory.allCases) { category in
                let isOn = model.categories.contains(category)
                Button {
                    model.toggle(category)
                } label: {
                    Text(category.rawValue)
                        .font(.App.caption)
                        .padding(.horizontal, Theme.spacing8)
                        .padding(.vertical, Theme.spacing4)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isOn ? Color.accentColor : .secondary)
                .background {
                    if isOn {
                        Capsule().fill(.tint.opacity(0.16))
                    }
                }
                .help(t("log.category.\(category.rawValue)"))
                // A filter that is on or off, not a button that fires: tint
                // alone carries that visually, and carries nothing to
                // VoiceOver or to anyone who cannot separate the two colours.
                .accessibilityLabel(t("log.category.\(category.rawValue)"))
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    private var levelPicker: some View {
        Picker(t("log.level"), selection: $model.minimumLevel) {
            Text(t("log.level.info")).tag(LogLevel.info)
            Text(t("log.level.notice")).tag(LogLevel.notice)
            Text(t("log.level.error")).tag(LogLevel.error)
        }
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
    }

    private var controls: some View {
        HStack(spacing: 2) {
            Button {
                model.isPaused.toggle()
            } label: {
                Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
            }
            .help(model.isPaused ? t("log.resume") : t("log.pause"))
            .accessibilityLabel(model.isPaused ? t("log.resume") : t("log.pause"))

            Button {
                let board = NSPasteboard.general
                board.clearContents()
                board.setString(model.text, forType: .string)
            } label: {
                Image(systemName: "document.on.document")
            }
            .disabled(model.lines.isEmpty)
            .help(t("log.copy"))
            .accessibilityLabel(t("log.copy"))

            Button {
                model.clear()
            } label: {
                Image(systemName: "eraser")
            }
            .disabled(model.lines.isEmpty)
            .help(t("log.clear"))
            .accessibilityLabel(t("log.clear"))
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    // MARK: - lines

    /// Within a line's height of the end, which is close enough that the
    /// reader is following rather than reading back.
    private func isAtBottom(_ geometry: ScrollGeometry) -> Bool {
        geometry.contentSize.height <= geometry.containerSize.height
            || geometry.visibleRect.maxY >= geometry.contentSize.height - 16
    }

    private var lineList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.lines) { line in
                        LogRow(line: line).id(line.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.background.opacity(0.72))
            .overlay {
                if model.lines.isEmpty {
                    Text(t("log.empty"))
                        .font(.App.body)
                        .foregroundStyle(.tertiary)
                }
            }
            // Only follow the tail while running *and* while the reader is
            // still at it. Pausing was the only thing that stopped the follow
            // before, so scrolling back through a failure — the reason this
            // pane exists — was yanked to the bottom by the next line, and on
            // a chain logging steadily that is immediately.
            .onChange(of: model.lines.last?.id) { _, id in
                guard let id, !model.isPaused, isFollowingTail else { return }
                proxy.scrollTo(id, anchor: .bottom)
            }
            .onScrollPhaseChange { _, phase, context in
                if phase == .tracking || phase == .interacting {
                    isFollowingTail = false
                } else if phase == .idle {
                    isFollowingTail = isAtBottom(context.geometry)
                }
            }
            .onAppear {
                guard let id = model.lines.last?.id else { return }
                isFollowingTail = true
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }
}

private struct LogRow: View {
    let line: LogStore.Line

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(LogModel.timestamp.string(from: line.date))
                .foregroundStyle(.tertiary)
            Text(line.category.rawValue)
                .foregroundStyle(categoryColor)
                .frame(width: 44, alignment: .leading)
            Text(line.message)
                .foregroundStyle(line.level == .error ? Color.red : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.App.mono)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One hue per hop, so the eye can follow a single stage down the log
    /// without reading every category label.
    private var categoryColor: Color {
        switch line.category {
        case .call: return .purple
        case .tap: return .teal
        case .audio: return .orange
        case .socket: return .blue
        }
    }
}

#Preview {
    LogPane(model: LogModel(), isExpanded: .constant(true))
        .frame(width: 720)
}
