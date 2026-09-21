import SwiftUI

/// The live subtitle board: one card per utterance, newest at the bottom,
/// auto-scrolled so the in-progress line stays visible.
struct SubtitleView: View {
    @Bindable var model: SubtitleModel
    @State private var log = LogModel()
    @State private var isFollowingLatest = true
    private let tailID = "subtitle-tail"

    /// Collapsed by default, and remembered: the log is a debugging surface,
    /// but someone who opened it once is usually still debugging next launch.
    @AppStorage("logPaneExpanded") private var isLogExpanded = false

    var body: some View {
        transcriptList
            .background { AppCanvas() }
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                LogPane(model: log, isExpanded: $isLogExpanded)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            .toolbar { toolbarItems }
    }

    // MARK: - header

    /// Sits in a `safeAreaInset` rather than the window toolbar: the status
    /// and the transport are the app's primary controls during a call, and
    /// they stay put while the list scrolls under the glass.
    private var header: some View {
        // Five controls and a status pill do not fit the window's minimum
        // width on one line. Left as a single row they do not shrink — they
        // overflow, and what goes over the edge is whatever sits last, which
        // is Start. So the row is offered in two shapes and the widest one
        // that fits is used: everything on one line when there is room,
        // otherwise the pickers wrap to a second line under the status, where
        // they have the whole width to themselves and Start stays put.
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                statusPill
                Spacer(minLength: 8)

                if model.isRunning {
                    Text(sessionSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                AudioRoutingButton(model: model)
                transport
            }

            HStack(spacing: 12) {
                controls
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .glassCard(radius: 18)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var sessionSummary: String {
        let mode = model.mode.label
        let mine = Language.named(model.myLanguage)?.menuLabel ?? model.myLanguage
        let theirs = Language.named(model.theirLanguage)?.menuLabel ?? model.theirLanguage
        return "\(mode) · \(mine) ⇄ \(theirs)"
    }

    private var statusPill: some View {
        StatusPill(
            status: model.status,
            callState: model.callState,
            isSpeaking: model.isSpeaking
        )
    }

    @ViewBuilder
    private var controls: some View {
        // Which sides are listened to, and what is done with them: the
        // two questions Start answers, next to the languages it answers
        // them in.
        SessionControlGroup(t("subtitles.scope")) {
            ScopePicker(model: model)
        }

        SessionControlGroup(t("subtitles.mode")) {
            ModePicker(model: model)
        }

        // The two languages read as one control, because the pair is the
        // setting: "they speak X, I speak Y". A single picker would leave
        // the other half of a bidirectional call unexplained.
        SessionControlGroup(t("settings.translation.languages")) {
            LanguagePair(model: model)
        }
    }

    private var transport: some View {
        TransportButton(isRunning: model.isRunning) {
            if model.isRunning { model.stop() } else { model.start() }
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if model.entryCount > 0 {
                Text(t("subtitles.entryCount", model.entryCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        ToolbarItemGroup {
            // Reading controls, grouped into one menu rather than spread
            // across the toolbar: they are set once and then left alone, so
            // they should not each hold a permanent button beside the two
            // actions that are used repeatedly.
            DisplayMenu(model: model)

            Button {
                let board = NSPasteboard.general
                board.clearContents()
                board.setString(model.transcriptText, forType: .string)
            } label: {
                Label(t("subtitles.copyAll"), systemImage: "document.on.document")
            }
            .disabled(model.entryCount == 0)

            Button {
                withAnimation(.snappy) { model.clearEntries() }
            } label: {
                Label(t("subtitles.clear"), systemImage: "eraser")
            }
            .disabled(model.entryCount == 0)
        }
    }

    // MARK: - list

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // `ForEach` over the entries directly. The run-grouping a card
                // needs — whether the one above it came from the same side —
                // is carried on the entry itself rather than re-derived here
                // from an index: text streams in several times a second, and
                // enumerating the whole board on each of those redraws was
                // work proportional to a long call's length per delta.
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(model.visibleEntries) { entry in
                        EntryCard(
                            entry: entry,
                            showsTranslation: model.runningMode == .translate,
                            size: model.transcriptSize,
                            showsTime: model.showsTimestamps,
                            showsSource: model.showsSourceText,
                            continuesRun: entry.continuesRun
                        )
                            .id(entry.id)
                            // A turn that starts a new speaker's run gets the
                            // air; one continuing a run stays tight against
                            // the card above, so the board groups visually the
                            // way the conversation did.
                            .padding(.top, entry.startsNewSpeaker ? 10 : 0)
                            .transition(
                                .move(edge: entry.direction == .local ? .trailing : .leading)
                                .combined(with: .opacity)
                            )
                    }
                    Color.clear.frame(height: 1).id(tailID)
                }
                .padding(.horizontal, Theme.pageInset)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if model.entryCount == 0 {
                    EmptyState(
                        status: model.status,
                        mode: model.mode,
                        scope: model.scope
                    )
                }
            }
            .onChange(of: model.entries.last?.id) { _, id in
                guard id != nil, isFollowingLatest else { return }
                withAnimation(.easeOut(duration: 0.24)) {
                    proxy.scrollTo(tailID, anchor: .bottom)
                }
            }
            // The in-progress card grows as text streams in; following its
            // height keeps the newest words off the bottom edge.
            //
            // Driven off a coalesced tick rather than off the text itself:
            // the deltas arrive several times a second and each `scrollTo`
            // forces a layout pass over the list, so following them one for
            // one spent more time scrolling than drawing. The model raises
            // this at most once per frame's worth of deltas, which is as
            // often as the scroll position can actually change on screen.
            .onChange(of: model.scrollTick) { _, _ in
                guard model.entries.last != nil, isFollowingLatest else { return }
                proxy.scrollTo(tailID, anchor: .bottom)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height <= geometry.containerSize.height
                    || geometry.visibleRect.maxY >= geometry.contentSize.height - 24
            } action: { _, isAtBottom in
                if isAtBottom { isFollowingLatest = true }
            }
            .onScrollPhaseChange { _, phase, context in
                if phase == .tracking || phase == .interacting {
                    isFollowingLatest = false
                } else if phase == .idle {
                    let geometry = context.geometry
                    isFollowingLatest = geometry.contentSize.height
                        <= geometry.containerSize.height
                        || geometry.visibleRect.maxY
                            >= geometry.contentSize.height - 24
                }
            }
        }
    }
}

private struct AudioRoutingButton: View {
    @Bindable var model: SubtitleModel
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label(t("settings.tab.voice"), systemImage: "speaker.wave.2")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            AudioRoutingSettings(model: model)
                .frame(width: 520, height: 620)
        }
    }
}

// MARK: - entry

/// One utterance, laid out in the lane belonging to whoever said it.
///
/// Both directions share a single timeline rather than getting a column each:
/// a conversation is interleaved, and who answered whom is the part that is
/// lost when the two sides scroll independently. The lane — indent, alignment,
/// accent and the marker on the inner edge — is what separates them, so the
/// reading order stays chronological.
private struct EntryCard: View {
    let entry: SubtitleModel.Entry

    /// Whether this card is expected to carry a translation under its
    /// transcript. Transcribing there is none, so the transcript stops being a
    /// caption above the real content and becomes the content — read at full
    /// weight rather than in the secondary style it wears while translating.
    let showsTranslation: Bool

    /// How large the two text lines are set. Only these scale: the header and
    /// the timestamp stay put, so raising the size enlarges the words rather
    /// than the whole card uniformly.
    let size: SubtitleModel.TranscriptSize

    /// Whether the time the utterance began is written in the header.
    let showsTime: Bool

    /// Whether the source line is kept under a translation. Ignored when
    /// there is no translation to keep it under — hiding it there would leave
    /// an empty card.
    let showsSource: Bool

    /// True when the card directly above came from the same side, in which
    /// case the header is dropped: on a run of turns from one speaker the
    /// label repeats a fact the lane already carries, and the repetition is
    /// what makes a long board look busier than the conversation was.
    let continuesRun: Bool

    private var isLocal: Bool { entry.direction == .local }

    /// Distinct hues rather than the same accent twice: at a glance across a
    /// long board, colour is what says whose turn it was, and both stay legible
    /// on glass in either appearance.
    private var accent: Color { isLocal ? .teal : .indigo }

    /// Whether the source line is actually drawn. It always is while
    /// transcribing — it is the only line there is.
    private var drawsTranscript: Bool {
        guard !entry.transcript.isEmpty else { return false }
        return showsSource || !showsTranslation || entry.translation.isEmpty
    }

    /// Whether the source is being shown *under* a translation rather than as
    /// the content itself, which is what decides its weight and colour.
    private var transcriptIsSecondary: Bool {
        showsTranslation && !entry.translation.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !continuesRun { header }

            if drawsTranscript {
                Text(entry.transcript)
                    .font(.system(
                        size: transcriptIsSecondary ? size.secondary : size.primary,
                        weight: transcriptIsSecondary ? .regular : .medium
                    ))
                    .foregroundStyle(transcriptIsSecondary ? .secondary : .primary)
                    .textSelection(.enabled)
                    .lineSpacing(transcriptIsSecondary ? 1 : 3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !entry.translation.isEmpty {
                // A hairline in the lane's colour rather than a full divider:
                // the two lines are one utterance, and a rule across the card
                // would read as two. Only drawn when both are present, so a
                // card with the source hidden has nothing dangling above it.
                if drawsTranscript {
                    Capsule()
                        .fill(accent.opacity(0.28))
                        .frame(width: 26, height: 1.5)
                        .padding(.vertical, 1)
                }

                Text(entry.translation)
                    // The translation is what the reader is here for, so it
                    // carries the weight; the source stays a caption above it.
                    .font(.system(size: size.primary, weight: .medium))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
        .padding(.horizontal, 13)
        .contentCard(radius: Theme.bubbleRadius, accent: accent, castsShadow: false)
        // The in-progress card is marked so the eye knows where the text is
        // still changing — a tinted edge rather than a second background, so
        // it stays legible against glass in both appearances. It sits on the
        // lane's inner edge, where the two columns face each other.
        .overlay(alignment: isLocal ? .trailing : .leading) {
            if !entry.isComplete {
                Capsule()
                    .fill(accent)
                    .frame(width: 3)
                    .padding(.vertical, 10)
                    .padding(isLocal ? .trailing : .leading, 5)
            }
        }
        .frame(maxWidth: Theme.transcriptMeasure, alignment: .leading)
        // Indented away from its own edge so the two lanes are visibly offset
        // even when a card runs the full width of a sentence.
        .padding(isLocal ? .leading : .trailing, 52)
        .frame(
            maxWidth: .infinity,
            alignment: isLocal ? .trailing : .leading
        )
        .animation(.snappy(duration: 0.2), value: entry.isComplete)
    }

    private var header: some View {
        HStack(spacing: 5) {
            // Ordered so the speaker label always sits against the lane's
            // outer edge and the time trails it, mirrored per side — the two
            // columns read outward from their own margins rather than both
            // starting on the left.
            if isLocal, showsTime { timestamp }

            Image(systemName: entry.direction.systemImage)
                .font(.system(size: 9, weight: .semibold))
            Text(entry.direction.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(accent)

            if !isLocal, showsTime { timestamp }
        }
        .foregroundStyle(accent)
        .frame(maxWidth: .infinity, alignment: isLocal ? .trailing : .leading)
    }

    /// Tertiary and monospaced: present for anyone looking for it, quiet
    /// enough not to compete with the words on a board being read live.
    private var timestamp: some View {
        Text(entry.timeLabel)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
    }
}

// MARK: - session controls

/// Gives each compact control a readable name without turning the live header
/// into a settings form. The labels establish a clear scan order and remain
/// visible when the symbols themselves are unfamiliar.
private struct SessionControlGroup<Content: View>: View {
    private let title: String
    @ViewBuilder private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            content
        }
        .fixedSize()
    }
}

// MARK: - display

/// How the board is read: text size, timestamps, and whether the source line
/// is kept under a translation.
///
/// Unlike the header's controls these stay live mid-call — they change nothing
/// about the session, only what is drawn from it, and the moment someone wants
/// larger text is usually the moment a line is already streaming in.
private struct DisplayMenu: View {
    @Bindable var model: SubtitleModel

    var body: some View {
        Menu {
            Picker(t("display.size"), selection: $model.transcriptSize) {
                ForEach(SubtitleModel.TranscriptSize.allCases) { size in
                    Text(size.label).tag(size)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Toggle(t("display.timestamps"), isOn: $model.showsTimestamps)

            // Nothing to hide while transcribing: the source line is the only
            // line, so the switch would blank the board.
            Toggle(t("display.sourceText"), isOn: $model.showsSourceText)
                .disabled(model.runningMode == .transcribe)
        } label: {
            Label(t("display.menu"), systemImage: "textformat.size")
        }
        // Icon-only: the header below already runs to the window's minimum
        // width, and a labelled menu here is what pushes the toolbar into its
        // overflow chevron — taking Start with it, which is the one control
        // that must never need a resize to reach.
        .labelStyle(.iconOnly)
        .menuIndicator(.hidden)
        .help(t("display.menu.help"))
    }
}

// MARK: - scope

/// Which sides of the call are captured.
///
/// Icon-only, and unlabelled: the symbols — two people, one person, a
/// microphone — carry the distinction on their own, and a caption over every
/// control is what turns a toolbar into a form. The name is a tooltip away and
/// reads in full in Settings.
private struct ScopePicker: View {
    @Bindable var model: SubtitleModel

    var body: some View {
        Picker(t("subtitles.scope"), selection: $model.scope) {
            ForEach(SubtitleModel.CaptureScope.allCases) { scope in
                Image(systemName: scope.systemImage)
                    .help(scope.label)
                    .tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
        .disabled(model.isRunning)
        .help(t("subtitles.scope.help"))
    }
}

// MARK: - mode

/// Translate, or only write down what was said.
///
/// A segmented control rather than a menu: there are two choices, they are
/// opposites, and which one is active should be readable without opening
/// anything — it changes what every card on the board will contain.
private struct ModePicker: View {
    @Bindable var model: SubtitleModel

    var body: some View {
        Picker(t("subtitles.mode"), selection: $model.mode) {
            ForEach(SubtitleModel.SessionMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
        // Mid-session the sockets are already configured for one mode; the
        // pair beside it is frozen for the same reason.
        .disabled(model.isRunning)
        .help(t("subtitles.mode.help"))
    }
}

// MARK: - language pair

/// The whole setup, in one control: my language and theirs.
///
/// The pair determines everything else — each side is translated into the
/// other, so there is no direction to choose and no reverse channel to switch
/// on. That is why this sits in the header rather than in Settings: it is not a
/// preference, it is the thing the user came to set.
///
/// Read as a sentence — mine → theirs — rather than as two captioned menus.
/// The arrow between them is what says which is which, the way a system
/// conversion control does it, so neither needs a label of its own and the
/// pair occupies one line instead of two.
private struct LanguagePair: View {
    @Bindable var model: SubtitleModel

    var body: some View {
        HStack(spacing: 4) {
            picker(t("subtitles.myLanguage"), selection: $model.myLanguage)

            // Swapping is the one edit this control needs beyond the menus —
            // reaching the same state by hand means two picks and a moment of
            // both sides reading the same language. Doubling as the separator
            // that shows the direction keeps it from costing a slot.
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    model.swapLanguages()
                }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 1)
            }
            .buttonStyle(.borderless)
            .help(t("subtitles.swapLanguages"))

            picker(t("subtitles.theirLanguage"), selection: $model.theirLanguage)
        }
        .fixedSize()
        .disabled(model.isRunning)
    }

    /// A bare menu. Which side it sets is said by its position around the
    /// arrow and by its tooltip, not by a caption stacked above it.
    private func picker(
        _ label: String, selection: Binding<String>
    ) -> some View {
        Picker(label, selection: selection) {
            ForEach(Language.common) { language in
                Text(language.menuLabel).tag(language.code)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .help(label)
    }
}

// MARK: - status

private struct StatusPill: View {
    let status: SubtitleModel.Status
    let callState: CallState
    let isSpeaking: Bool

    var body: some View {
        HStack(spacing: 7) {
            Indicator(color: color, isLive: isLive)

            Text(status.label)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            // While synthesised speech is playing, the far end is hearing the
            // translation rather than us — worth saying, because nothing else
            // on screen distinguishes it from a silent moment.
            if isSpeaking {
                Label(t("status.speaking"), systemImage: "speaker.wave.2.fill")
                    .labelStyle(.iconOnly)
                    .font(.caption)
                    .foregroundStyle(.teal)
                    .symbolEffect(.variableColor.iterative)
                    .help(t("status.speaking"))
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }

            if case .active(let process) = callState {
                Text(t("status.pid", process.pid))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 11)
        .padding(.vertical, 5)
        .statusSurface(color)
        .help(status.label)
        .animation(.easeInOut(duration: 0.2), value: color)
        .animation(.snappy(duration: 0.2), value: isSpeaking)
    }

    private var isLive: Bool {
        if case .running = status { return true }
        return false
    }

    private var color: Color {
        switch status {
        case .idle: return .secondary
        case .waitingForCall, .connecting: return .orange
        case .running: return .green
        case .failed: return .red
        }
    }
}

/// A dot that breathes while subtitles are live, so a glance at the window
/// tells you the session is still running without reading the label.
private struct Indicator: View {
    let color: Color
    let isLive: Bool

    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay {
                if isLive {
                    Circle()
                        .stroke(color, lineWidth: 2)
                        .scaleEffect(isPulsing ? 2.4 : 1)
                        .opacity(isPulsing ? 0 : 0.7)
                }
            }
            .onChange(of: isLive, initial: true) { _, live in
                isPulsing = false
                guard live else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    isPulsing = true
                }
            }
    }
}

// MARK: - transport

private struct TransportButton: View {
    let isRunning: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(
                isRunning ? t("subtitles.stop") : t("subtitles.start"),
                systemImage: isRunning ? "stop.fill" : "play.fill"
            )
            .font(.callout.weight(.medium))
            .frame(minWidth: 48)
        }
        .buttonStyle(.borderedProminent)
        // Regular rather than large: it is still the row's only filled
        // button, which is what makes it the primary one — at large it also
        // set the height of the whole bar.
        .controlSize(.large)
        .tint(isRunning ? .red : .accentColor)
        .keyboardShortcut(.return, modifiers: .command)
    }
}

// MARK: - empty state

private struct EmptyState: View {
    let status: SubtitleModel.Status
    /// The mode Start would begin, so the idle screen describes what is about
    /// to happen rather than what the other mode would have done.
    let mode: SubtitleModel.SessionMode
    /// Likewise the scope, which decides whether there is a call to answer at
    /// all — the microphone alone needs none.
    let scope: SubtitleModel.CaptureScope

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: isWaiting)
                .frame(width: 72, height: 72)
                .background(.tint.opacity(0.10), in: Circle())
                .overlay { Circle().strokeBorder(.tint.opacity(0.14), lineWidth: 1) }
                .padding(.bottom, 4)

            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(40)
        .accessibilityElement(children: .combine)
    }

    private var isWaiting: Bool {
        switch status {
        case .connecting, .waitingForCall, .running: return true
        default: return false
        }
    }

    private var symbol: String {
        switch status {
        case .idle: return "text.bubble"
        case .connecting: return "antenna.radiowaves.left.and.right"
        case .waitingForCall: return "phone.badge.waveform"
        case .running: return "waveform"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch status {
        case .idle: return t("empty.idle.title")
        case .connecting: return t("empty.connecting.title")
        case .waitingForCall: return t("empty.waitingForCall.title")
        case .running: return t("empty.running.title")
        case .failed: return t("empty.failed.title")
        }
    }

    private var message: String {
        switch status {
        case .idle:
            // Capturing our own side alone involves no call, so the usual
            // "answer your iPhone" instruction would be wrong rather than
            // merely incomplete.
            if scope == .localOnly {
                return mode == .transcribe
                    ? t("empty.idle.message.localOnly.transcribe")
                    : t("empty.idle.message.localOnly")
            }
            return mode == .transcribe
                ? t("empty.idle.message.transcribe")
                : t("empty.idle.message")
        case .connecting: return t("empty.connecting.message")
        case .waitingForCall: return t("empty.waitingForCall.message")
        case .running: return t("empty.running.message")
        case .failed(let message): return message
        }
    }
}

// The seeded previews call into a DEBUG-only helper on the model, so they
// have to be compiled out of a release build alongside it.
#if DEBUG
#Preview("Translating") {
    let model = SubtitleModel()
    model.seedSampleBoard()
    return SubtitleView(model: model)
        .frame(width: 900, height: 620)
}

#Preview("Transcribing") {
    let model = SubtitleModel()
    model.seedSampleBoard(mode: .transcribe)
    return SubtitleView(model: model)
        .frame(width: 900, height: 620)
}

/// The largest size against the narrowest window the app allows: the two ends
/// the measure and the lane indent have to survive together.
#Preview("Extra large, narrow") {
    let model = SubtitleModel()
    model.seedSampleBoard()
    model.transcriptSize = .extraLarge
    return SubtitleView(model: model)
        .frame(width: 720, height: 620)
}

#endif

#Preview("Empty") {
    SubtitleView(model: SubtitleModel())
        .frame(width: 720, height: 520)
}
