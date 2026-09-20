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
        .glassCard(radius: 14)
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .animation(.snappy(duration: 0.22), value: isExpanded)
    }

    // MARK: - header

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Label(t("log.title"), systemImage: "list.bullet.rectangle")
                        .font(.callout.weight(.medium))
                        .labelStyle(.titleAndIcon)
                }
            }
            .buttonStyle(.plain)
            .help(t("log.toggle.help"))

            if !isExpanded, let last = model.lines.last {
                // Collapsed, the pane still says what the chain last did —
                // enough to notice a stall without opening it.
                Text(last.message)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if isExpanded {
                categoryChips
                levelPicker
            }

            Text(t("log.lineCount", model.lines.count))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()

            controls
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
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
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isOn ? Color.accentColor : .secondary)
                .background {
                    if isOn {
                        Capsule().fill(.tint.opacity(0.16))
                    }
                }
                .help(t("log.category.\(category.rawValue)"))
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

            Button {
                let board = NSPasteboard.general
                board.clearContents()
                board.setString(model.text, forType: .string)
            } label: {
                Image(systemName: "document.on.document")
            }
            .disabled(model.lines.isEmpty)
            .help(t("log.copy"))

            Button {
                model.clear()
            } label: {
                Image(systemName: "eraser")
            }
            .disabled(model.lines.isEmpty)
            .help(t("log.clear"))
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    // MARK: - lines

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
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
            // Only follow the tail while running: scrolling back through a
            // failure should not be yanked to the bottom by the next line.
            .onChange(of: model.lines.last?.id) { _, id in
                guard let id, !model.isPaused else { return }
                proxy.scrollTo(id, anchor: .bottom)
            }
            .onAppear {
                guard let id = model.lines.last?.id else { return }
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
        .font(.system(size: 11, design: .monospaced))
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
