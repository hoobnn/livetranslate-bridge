import SwiftUI

/// The live subtitle board: the conversation, set as subtitles, with the
/// session's controls collapsed into a single bar above it.
///
/// The bar is the redesign's main move. Scope, mode and the language pair used
/// to sit on the board permanently as three captioned pickers — a settings
/// form pinned over the content, six controls deep, none of which can be
/// touched once a session is running. They are now one line that *states* the
/// session ("中文 ⇄ English · 翻译 · 双向") and opens a popover to change it,
/// so the board keeps the width and the eye keeps the words.
struct SubtitleView: View {
    @Bindable var model: SubtitleModel
    var isActive = true
    @State private var sourceName = ""
    @State private var sourceIcon: NSImage?
    @State private var confirmsClear = false
    @State private var didCopy = false
    @State private var copyFeedbackTask: Task<Void, Never>?
    @State private var log = LogModel()
    @State private var isFollowingLatest = true
    @State private var isUserScrolling = false
    @State private var isShowingSetup = false
    private let tailID = "subtitle-tail"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Collapsed by default, and remembered: the log is a debugging surface,
    /// but someone who opened it once is usually still debugging next launch.
    @AppStorage("logPaneExpanded") private var isLogExpanded = false

    var body: some View {
        transcriptList
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 8) {
                    header
                    HStack(spacing: 6) {
                        Label {
                            Text(model.scope == .localOnly
                                 ? t("settings.audio.input.section") : sourceName)
                        } icon: {
                            if model.scope == .localOnly {
                                Image(systemName: "mic.fill")
                                    .foregroundStyle(Theme.localLane)
                            } else if let sourceIcon {
                                Image(nsImage: sourceIcon)
                                    .resizable()
                                    .interpolation(.high)
                                    .scaledToFit()
                                    .frame(width: 18, height: 18)
                                    .accessibilityHidden(true)
                            } else {
                                Image(systemName: "app")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .lineLimit(1)
                        .help(model.scope == .localOnly
                              ? t("settings.audio.input.section") : sourceName)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(model.scope == .localOnly
                                            ? t("settings.audio.input.section") : sourceName)
                        .accessibilityIdentifier("session.source")
                        Spacer()
                        StatusPill(status: model.status, callState: model.callState,
                                   isSpeaking: model.isSpeaking)
                        if model.entryCount > 0 {
                            Text(t("subtitles.entryCount", model.entryCount))
                                .monospacedDigit()
                        }
                    }
                    .font(.App.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 4)
                    if let notice = model.audioNotice, model.isRunning {
                        Label(notice, systemImage: "waveform.badge.exclamationmark")
                            .font(.App.caption)
                            .foregroundStyle(Theme.pending)
                            .padding(.horizontal, 24)
                    }
                    if case .failed(let message) = model.status, model.entryCount > 0 {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.failure)
                            Text(message).textSelection(.enabled)
                            Spacer(minLength: 0)
                            SettingsLink { Text(t("ux.settings")) }
                        }
                        .font(.App.body)
                        .padding(12)
                        .contentCard()
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 12)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(alignment: .bottom) { Divider() }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                LogPane(model: log, isExpanded: $isLogExpanded)
                    .padding(.horizontal, Theme.spacing16)
                    .padding(.bottom, Theme.spacing12)
            }
            .toolbar { if isActive { toolbarItems } }
            .confirmationDialog(t("ux.clear.title"), isPresented: $confirmsClear,
                                titleVisibility: .visible) {
                Button(t("subtitles.clear"), role: .destructive) {
                    model.clearEntries()
                    isFollowingLatest = true
                }
                .accessibilityIdentifier("transcript.confirmClear")
                Button(t("ux.cancel"), role: .cancel) { }
                    .accessibilityIdentifier("transcript.cancelClear")
            } message: {
                Text(t("ux.clear.message"))
            }
            .task(id: model.sourceBundleID) {
                let bundleID = model.sourceBundleID
                sourceIcon = nil
                sourceName = bundleID
                let identity = await Task.detached(priority: .utility) {
                    // The FaceTime audio service has no app bundle of its own.
                    let appID = bundleID == "com.apple.avconferenced"
                        ? "com.apple.FaceTime" : bundleID
                    let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID)
                    let name = url.map {
                        FileManager.default.displayName(atPath: $0.path)
                            .replacingOccurrences(of: ".app", with: "")
                    } ?? (bundleID == "com.apple.avconferenced" ? "FaceTime" : bundleID)
                    return (name, url)
                }.value
                guard !Task.isCancelled else { return }
                sourceName = identity.0
                // Resolve once per source change, never during streaming body updates.
                sourceIcon = identity.1.map { NSWorkspace.shared.icon(forFile: $0.path) }
            }
            .onDisappear { copyFeedbackTask?.cancel() }
    }

    // MARK: - header

    /// One bar: what the session is, and the button that starts it.
    ///
    /// It floats over the board in a `safeAreaInset` rather than sitting in
    /// the window toolbar, because Start is the app's primary control during
    /// a call and the toolbar is where macOS puts things you reach for
    /// occasionally.
    private var header: some View {
        HStack(spacing: Theme.spacing12) {
            SessionSummaryButton(model: model, isPresented: $isShowingSetup)

            Spacer(minLength: Theme.spacing8)

            AudioRoutingButton(model: model)

            if model.isRunning, model.mode == .translate {
                Button(t("audio.skipSpeech"), systemImage: "forward.end") {
                    model.interruptTranslation()
                }
                .help(t("audio.skipSpeech.help"))
            }
            TransportButton(isRunning: model.isRunning) {
                if model.isRunning { model.stop() } else { model.start() }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // Reading controls, grouped into one menu rather than spread
            // across the toolbar: they are set once and then left alone, so
            // they should not each hold a permanent button beside the two
            // actions that are used repeatedly.
            DisplayMenu(model: model)

            Button {
                let board = NSPasteboard.general
                board.clearContents()
                guard board.setString(model.transcriptText, forType: .string) else { return }
                didCopy = true
                copyFeedbackTask?.cancel()
                copyFeedbackTask = Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    didCopy = false
                }
            } label: {
                Label(t(didCopy ? "ux.copied" : "subtitles.copyAll"),
                      systemImage: didCopy ? "checkmark" : "document.on.document")
            }
            .disabled(model.entryCount == 0)
            .help(t(didCopy ? "ux.copied" : "subtitles.copyAll"))
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .accessibilityIdentifier("transcript.copy")

            Button {
                confirmsClear = true
            } label: {
                Label(t("subtitles.clear"), systemImage: "eraser")
            }
            .disabled(model.entryCount == 0)
            .help(t("subtitles.clear"))
            .accessibilityIdentifier("transcript.clear")
        }
    }

    // MARK: - list

    /// The line length the board is laid out to, which follows the reader's
    /// chosen text size rather than being one number for all four.
    private var measure: CGFloat {
        Theme.transcriptMeasure(for: model.transcriptSize.primary)
    }

    private var transcriptList: some View {
        // The lane offset depends on how much width the board actually got,
        // which only the layout knows. Read once here, around the list,
        // rather than per row: it is the same value for every turn, and the
        // board redraws many times a second while text streams in.
        GeometryReader { geometry in
            let board = min(geometry.size.width, Theme.boardMaxWidth)
            transcriptScroll(gutter: Theme.gutter(boardWidth: board))
        }
    }

    private func transcriptScroll(gutter: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // `ForEach` over the entries directly. The run-grouping a card
                // needs — whether the one above it came from the same side —
                // is carried on the entry itself rather than re-derived here
                // from an index: text streams in several times a second, and
                // enumerating the whole board on each of those redraws was
                // work proportional to a long call's length per delta.
                // Turns within a run sit close; a new speaker gets air. The
                // rhythm is what groups the board, now that no card border
                // does it.
                LazyVStack(alignment: .leading, spacing: Theme.spacing8) {
                    ForEach(model.visibleEntries) { row in
                        EntryCard(
                            entry: row.entry,
                            showsTranslation: model.runningMode == .translate,
                            size: model.transcriptSize,
                            showsTime: model.showsTimestamps,
                            showsSource: model.showsSourceText,
                            continuesRun: row.continuesRun,
                            measure: measure
                        )
                            .id(row.id)
                            // A turn that starts a new speaker's run gets the
                            // air; one continuing a run stays tight against
                            // the card above, so the board groups visually the
                            // way the conversation did.
                            .padding(.top, row.startsNewSpeaker ? Theme.spacing16 : 0)
                            // Cards fade in where they sit. They used to fly
                            // in from their own lane's edge, a full sideways
                            // sweep across the board for every turn — which
                            // is a lot of motion on a surface that gains a
                            // line every few seconds, and reads as the board
                            // twitching rather than as a turn arriving.
                            .transition(.opacity)
                    }
                    Color.clear.frame(height: 1).id(tailID)
                }
                // The gutter opens up with the window. A fixed 20 pt is a
                // reasonable margin at the minimum size and a hairline at
                // 1400, where it left the first turn apparently touching the
                // window's edge while the opposite lane had room to spare.
                .padding(.horizontal, gutter)
                .padding(.vertical, Theme.spacing20)
                // The board follows the window up to a cap, then centres in
                // what is left over.
                //
                // Both frames are needed, and in this order: the first caps
                // the board, the second claims the window's full width so the
                // capped board has something to centre within. A `maxWidth`
                // frame only positions its own content; on its own it leaves
                // the board against the leading edge.
                .frame(maxWidth: Theme.boardMaxWidth, alignment: .center)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if model.entryCount == 0 {
                    EmptyState(
                        status: model.status,
                        mode: model.mode,
                        scope: model.scope
                    )
                    // The placeholder is a sign, not a surface: left hit-
                    // testable it sat over the full scroll area and ate the
                    // scroll and text-selection the board underneath expects
                    // the moment the first card arrives.
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .animation(Theme.settle, value: model.entryCount == 0)
            // Scrolling back during a live call silently stops the board
            // following the newest line — correct, but until now there was no
            // way back except dragging to the bottom by hand, and on a board
            // still growing several times a second that is a moving target.
            .overlay(alignment: .bottom) {
                if !isFollowingLatest, model.entryCount > 0 {
                    JumpToLatestButton {
                        isFollowingLatest = true
                        withAnimation(Theme.settle) {
                            proxy.scrollTo(tailID, anchor: .bottom)
                        }
                    }
                    .padding(.bottom, 12)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
                }
            }
            .animation(Theme.arrive, value: isFollowingLatest)
            .onAppear {
                if isFollowingLatest { proxy.scrollTo(tailID, anchor: .bottom) }
            }
            .onChange(of: model.entries.last?.id) { _, id in
                guard id != nil, isFollowingLatest else { return }
                proxy.scrollTo(tailID, anchor: .bottom)
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
                if isAtBottom && !isUserScrolling { isFollowingLatest = true }
            }
            .onScrollPhaseChange { _, phase, context in
                if phase == .tracking || phase == .interacting {
                    isUserScrolling = true
                    isFollowingLatest = false
                } else if phase == .idle {
                    isUserScrolling = false
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

// MARK: - follow

/// Returns the board to the newest line after the reader has scrolled back.
///
/// A floating control rather than a bar: it exists only while the board is not
/// following, and it sits over the transcript instead of taking a permanent
/// strip from it.
private struct JumpToLatestButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(t("subtitles.jumpToLatest"), systemImage: "arrow.down")
                .font(.App.label)
                .padding(.horizontal, Theme.spacing12)
                .padding(.vertical, Theme.spacing8)
        }
        .buttonStyle(.plain)
        .glassCard(radius: 999)
        .help(t("subtitles.jumpToLatest"))
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
            // A height the popover may shrink below rather than one it must
            // have: five sections of routing is taller than a laptop screen
            // leaves above the header on 13-inch hardware, and a fixed 620
            // there clipped the last section instead of scrolling to it.
            AudioRoutingSettings(model: model)
                .frame(width: 520)
                .frame(minHeight: 420, idealHeight: 620, maxHeight: 620)
        }
    }
}

// MARK: - entry

/// One utterance, set as a subtitle rather than drawn as a chat bubble.
///
/// The old card wrapped every line in a filled, bordered, shadowed box with a
/// header above it. On a board that is mostly text, that chrome outweighed the
/// words: six visual elements per utterance, of which one was the utterance.
///
/// What remains is what actually distinguishes the two sides — a coloured rail
/// on the lane's inner edge, the indent, and a small label that only appears
/// when the speaker changes. Everything else is type: the translation large and
/// full-weight, the source small and quiet beneath it. The eye lands on the
/// words because there is nothing else to land on.
///
/// Both directions still share one timeline rather than getting a column each:
/// a conversation is interleaved, and who answered whom is what is lost when
/// the two sides scroll independently.
private struct EntryCard: View {
    let entry: SubtitleModel.Entry

    /// Whether this card is expected to carry a translation under its
    /// transcript. Transcribing there is none, so the transcript stops being a
    /// caption above the real content and becomes the content — read at full
    /// weight rather than in the secondary style it wears while translating.
    let showsTranslation: Bool

    /// How large the two text lines are set. Only these scale: the label and
    /// the timestamp stay put, so raising the size enlarges the words rather
    /// than the whole row uniformly.
    let size: SubtitleModel.TranscriptSize

    /// Whether the time the utterance began is written beside the label.
    let showsTime: Bool

    /// Whether the source line is kept under a translation. Ignored when
    /// there is no translation to keep it under — hiding it there would leave
    /// an empty row.
    let showsSource: Bool

    /// True when the row directly above came from the same side, in which
    /// case the label is dropped: on a run of turns from one speaker it
    /// repeats a fact the rail already carries, and the repetition is what
    /// makes a long board look busier than the conversation was.
    let continuesRun: Bool

    /// The line length this row is set to, passed in rather than recomputed
    /// per row: it is the same for every row on the board, and the board is
    /// redrawn many times a second while text streams in.
    let measure: CGFloat

    private var isLocal: Bool { entry.direction == .local }
    private var accent: Color { Theme.lane(isLocal) }

    /// Whether the source line is actually drawn. It always is while
    /// transcribing — it is the only line there is.
    private var drawsTranscript: Bool {
        guard entry.hasTranscript else { return false }
        return showsSource || !showsTranslation || !entry.hasTranslation
    }

    /// Whether the source is being shown *under* a translation rather than as
    /// the content itself, which is what decides its weight and colour.
    private var transcriptIsSecondary: Bool {
        showsTranslation && entry.hasTranslation
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.spacing12) {
            // The rail goes on the speaker's own side — the far end's turns
            // are railed left, ours right — so it lands against the margin
            // the turn is aligned to instead of cutting through the middle
            // of the board.
            if isLocal { text } else { rail }
            if isLocal { rail } else { text }
        }
        // The turn sits on its own side of the board: the far end left, us
        // right, the way a conversation is laid out everywhere else.
        //
        // Two frames, and the order matters. The first caps the row at the
        // measure, so a long turn wraps rather than running the full width
        // of a wide window. The second claims the board and pushes the
        // capped row to its speaker's edge.
        //
        // What makes this read correctly is that the row is sized to fit its
        // text — the `Text` views inside report their own width, and nothing
        // here forces the row to fill the measure it is merely allowed. A
        // frame with `maxWidth` is a ceiling, not a demand. Getting that
        // wrong is what left a three-word line starting in the middle of the
        // window with its rail nowhere near either side: the row had claimed
        // the whole measure and aligned *that* to the edge, not the words.
        .frame(maxWidth: measure, alignment: isLocal ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: isLocal ? .trailing : .leading)
        // Who spoke is carried visually by the rail, the colour and the side
        // of the board — none of which survives into VoiceOver, so the
        // speaker is named in the label instead. `.contain` keeps the two text runs
        // individually selectable inside the row.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entry.direction.label)
    }

    /// The rail. It replaces the card's border, its fill and its shadow all
    /// at once: one 3 pt stroke down the turn's outer edge says whose turn it
    /// is and how tall the turn was, and it is the only non-text mark the row
    /// draws.
    ///
    /// It brightens while the text is still streaming, so the live line is
    /// findable without a second background behind it.
    private var rail: some View {
        Capsule()
            .fill(accent.opacity(entry.isComplete ? 0.45 : 1))
            .frame(width: 3)
            .animation(Theme.quick, value: entry.isComplete)
    }

    /// The label and the words, aligned to the turn's own side so a wrapped
    /// line stays flush with the margin the row sits against.
    private var text: some View {
        VStack(alignment: isLocal ? .trailing : .leading, spacing: Theme.spacing4) {
            if !continuesRun { speakerLabel }
            lines
        }
    }

    @ViewBuilder
    private var lines: some View {
        // The translation first and largest: it is what the reader is here
        // for. The source follows as a caption, which is the relationship
        // between them — the old layout put the source on top, where it read
        // as the heading of the sentence below it.
        if entry.hasTranslation {
            Text(entry.translation)
                .font(.system(size: size.primary, weight: .regular))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineSpacing(size.primary * 0.28)
                // A wrapped turn is ragged on the side away from its margin,
                // so each side's text is set toward its own edge.
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let status = entry.responseStatus, status != "completed", status != "in_progress" {
            Label(t("subtitles.responseInterrupted"), systemImage: "exclamationmark.bubble")
                .font(.App.caption).foregroundStyle(Theme.pending)
        }
        if drawsTranscript {
            Text(entry.transcript)
                .font(.system(
                    size: transcriptIsSecondary ? size.secondary : size.primary,
                    weight: .regular
                ))
                .foregroundStyle(transcriptIsSecondary ? .secondary : .primary)
                .textSelection(.enabled)
                .lineSpacing(
                    (transcriptIsSecondary ? size.secondary : size.primary) * 0.24
                )
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, transcriptIsSecondary ? Theme.spacing2 : 0)
        }
    }

    /// Who is speaking, and when. Set as an eyebrow rather than as a titled
    /// header: it is a tag on the turn, not a heading over it.
    private var speakerLabel: some View {
        HStack(spacing: Theme.spacing6) {
            // The name keeps the rail's side and the time follows it
            // outward, so on our turns the pair reads inward from the right
            // margin rather than trailing off toward the board's middle.
            if isLocal, showsTime { timeLabel }

            Text(entry.direction.label)
                .font(.App.eyebrow)
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(accent)

            if !isLocal, showsTime { timeLabel }
        }
    }

    private var timeLabel: some View {
        Text(entry.timeLabel)
            .font(.App.numeric)
            .foregroundStyle(.secondary)
    }
}

// MARK: - session setup

/// What the session is, as a sentence, and the way to change it.
///
/// This replaces three captioned pickers that sat on the board permanently.
/// The setup is read far more often than it is edited — and while a session
/// runs it *cannot* be edited — so it is shown as text and edited in a
/// popover, which is what macOS does with a setting you state more than you
/// touch.
private struct SessionSummaryButton: View {
    @Bindable var model: SubtitleModel
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: Theme.spacing8) {
                // The language pair leads, because it is the thing the user
                // came to set. Each side wears its own lane's colour, so the
                // bar and the board below agree on who is who.
                HStack(spacing: Theme.spacing4) {
                    Text(shortLabel(model.myLanguage))
                        .foregroundStyle(Theme.localLane)
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                    Text(shortLabel(model.theirLanguage))
                        .foregroundStyle(Theme.remoteLane)
                }
                .font(.App.label)

                Text(verbatim: "·").foregroundStyle(.quaternary)

                Text(model.mode.label)
                    .font(.App.caption)
                    .foregroundStyle(.secondary)

                Text(verbatim: "·").foregroundStyle(.quaternary)

                Text(model.scope.label)
                    .font(.App.caption)
                    .foregroundStyle(.secondary)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .lineLimit(1)
            .padding(.vertical, Theme.spacing8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(t("subtitles.setup.help"))
        .accessibilityIdentifier("session.setup")
        .accessibilityLabel(t("subtitles.setup"))
        .accessibilityValue(summary)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            SessionSetupPopover(model: model)
        }
    }

    /// The endonym alone. `menuLabel` adds the localized name after it —
    /// right in a menu, where the two names disambiguate a long list, but in
    /// the bar "English · 英语" says the same word twice in a line that is
    /// meant to be read at a glance.
    private func shortLabel(_ code: String) -> String {
        Language.named(code)?.endonym ?? code
    }

    private func label(_ code: String) -> String {
        Language.named(code)?.menuLabel ?? code
    }

    private var summary: String {
        "\(label(model.myLanguage)) ⇄ \(label(model.theirLanguage))"
            + " · \(model.mode.label) · \(model.scope.label)"
    }
}

/// The session's three settings, laid out as a form rather than as a row of
/// compact controls — a popover has the room a header does not, so each one
/// gets its full name and an explanation of what it changes.
private struct SessionSetupPopover: View {
    @Bindable var model: SubtitleModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing20) {
            Text(t("subtitles.setup"))
                .font(.App.title)

            field(t("settings.translation.languages"),
                  note: t("subtitles.setup.languages.note")) {
                LanguagePair(model: model)
            }

            field(t("subtitles.mode"), note: model.mode.explanation) {
                ModePicker(model: model)
            }

            field(t("subtitles.scope"), note: model.scope.explanation) {
                ScopePicker(model: model)
            }

            if model.isRunning {
                // Everything above is frozen mid-session; saying so once here
                // is clearer than three separately greyed controls with no
                // stated reason.
                Label(t("subtitles.setup.locked"), systemImage: "lock")
                    .font(.App.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 370)
        .background(Color(light: Color(white: 0.97), dark: Color(white: 0.16)))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(.separator.opacity(0.4), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func field(
        _ title: String,
        note: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing6) {
            Text(title).font(.App.label).foregroundStyle(.secondary)
            content()
            Text(note)
                .font(.App.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
/// Symbol *and* name, now that this lives in the setup popover rather than in
/// the header: the three symbols are only obvious once you already know the
/// three choices, and the popover has the width to simply say them.
private struct ScopePicker: View {
    @Bindable var model: SubtitleModel

    var body: some View {
        AlignedSegments(values: SubtitleModel.CaptureScope.allCases,
                        titles: SubtitleModel.CaptureScope.allCases.map(\.label),
                        selection: $model.scope, label: t("subtitles.scope"))
        .frame(width: 322, height: 28)
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
        AlignedSegments(values: SubtitleModel.SessionMode.allCases,
                        titles: SubtitleModel.SessionMode.allCases.map(\.label),
                        selection: $model.mode, label: t("subtitles.mode"))
        .frame(width: 322, height: 28)
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
        HStack(alignment: .bottom, spacing: Theme.spacing8) {
            picker(t("subtitles.myLanguage"), selection: $model.myLanguage)

            // Swapping is the one edit this control needs beyond the menus —
            // reaching the same state by hand means two picks and a moment of
            // both sides reading the same language. Doubling as the separator
            // that shows the direction keeps it from costing a slot.
            Button {
                withAnimation(Theme.quick) {
                    model.swapLanguages()
                }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help(t("subtitles.swapLanguages"))
            .accessibilityLabel(t("subtitles.swapLanguages"))

            picker(t("subtitles.theirLanguage"), selection: $model.theirLanguage)
        }
        .disabled(model.isRunning)
    }

    /// A bare menu. Which side it sets is said by its position around the
    /// arrow and by its tooltip, not by a caption stacked above it.
    private func picker(
        _ label: String, selection: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.App.caption).foregroundStyle(.secondary)
            AlignedLanguagePicker(selection: selection, label: label)
                .frame(width: 139, height: 28)
            .help(label)
        }
        .frame(width: 139, alignment: .leading)
    }
}

// MARK: - status

private struct StatusPill: View {
    let status: SubtitleModel.Status
    let callState: CallState
    let isSpeaking: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var compactLabel: String {
        if case .failed = status { return t("empty.failed.title") }
        return status.label
    }

    var body: some View {
        HStack(spacing: Theme.spacing6) {
            Indicator(color: color)

            Text(compactLabel)
                .font(.App.label)
                .foregroundStyle(color)
                .lineLimit(1)

            // While synthesised speech is playing, the far end is hearing the
            // translation rather than us — worth saying, because nothing else
            // on screen distinguishes it from a silent moment.
            if isSpeaking {
                Label(t("status.speaking"), systemImage: "speaker.wave.2.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 10))
                    .foregroundStyle(color)
                    .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                    .help(t("status.speaking"))
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.vertical, 2)
        // The tapped process's pid used to sit here, in the app's most
        // prominent readout. It is a debugging fact — the diagnostics pane
        // states it in full — and in the status bar it read as an error code
        // attached to a healthy session.
        .help(pidHelp ?? status.label)
        .animation(Theme.quick, value: color)
        .animation(Theme.quick, value: isSpeaking)
        // One element rather than four: the dot, the label, the speaking
        // symbol and the pid are one readout, and read separately the dot
        // and the symbol are unlabelled images.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.label)
        .accessibilityValue(isSpeaking ? t("status.speaking") : "")
    }

    /// The pid moves into the tooltip: available to anyone who wants it,
    /// absent from the line everyone else reads.
    private var pidHelp: String? {
        guard case .active(let process) = callState else { return nil }
        return "\(status.label) · \(t("status.pid", process.pid))"
    }

    private var color: Color {
        switch status {
        case .idle: return .secondary
        case .waitingForCall, .connecting: return Theme.pending
        case .running: return Theme.live
        case .failed: return Theme.failure
        }
    }
}

/// A quiet status marker. The adjacent label carries the state without animation.
private struct Indicator: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }
}

// MARK: - transport

private struct TransportButton: View {
    let isRunning: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if isRunning {
                Button(action: action) { label }
                    .buttonStyle(.bordered)
            } else {
                Button(action: action) { label }
                    .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.regular)
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityIdentifier("session.transport")
    }

    private var label: some View {
        Label(isRunning ? t("subtitles.stop") : t("subtitles.start"),
              systemImage: isRunning ? "stop.fill" : "play.fill")
            .font(.App.label)
            .frame(minWidth: 54)
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Theme.spacing16) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            VStack(spacing: Theme.spacing8) {
                Text(title)
                    .font(.system(size: 20, weight: .medium))
                    .tracking(-0.2)
                    .foregroundStyle(.primary)

                Text(message)
                    .font(.App.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 380)
            }
        }
        .padding(Theme.spacing28)
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
        .background { AppCanvas() }
        .frame(width: 900, height: 620)
}

#Preview("Transcribing") {
    let model = SubtitleModel()
    model.seedSampleBoard(mode: .transcribe)
    return SubtitleView(model: model)
        .background { AppCanvas() }
        .frame(width: 900, height: 620)
}

/// The largest size against the narrowest window the app allows: the two ends
/// the measure and the lane indent have to survive together.
#Preview("Extra large, narrow") {
    let model = SubtitleModel()
    model.seedSampleBoard()
    model.transcriptSize = .extraLarge
    return SubtitleView(model: model)
        .background { AppCanvas() }
        .frame(width: 720, height: 620)
}

// No preview for the accessibility surfaces: `accessibilityReduceMotion`,
// `accessibilityReduceTransparency` and `colorSchemeContrast` are all
// read-only environment values derived from the system, so a preview cannot
// inject them. The opaque fallbacks are checked by turning "Reduce motion",
// "Reduce transparency" and "Increase contrast" on in System Settings ›
// Accessibility › Display with the app running.

#endif

#Preview("Empty") {
    SubtitleView(model: SubtitleModel())
        .background { AppCanvas() }
        .frame(width: 720, height: 520)
}
