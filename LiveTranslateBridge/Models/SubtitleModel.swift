import os
import AVFoundation
import Foundation
import Observation

/// Drives the subtitle view: owns the call session and the translation sockets,
/// and turns their callbacks into observable state.
///
/// A call has two sides, and each gets its own socket. The far end is captured
/// from the process tap and translated into the user's language; the user is
/// captured from the microphone and translated into the far end's. The two are
/// symmetric except in what happens to the result — the far end's translation
/// is only ever read, while the user's can also be spoken back out (see
/// `TranslationPlayer`).
///
/// Everything below the model runs on Core Audio and URLSession threads, so
/// every callback hops to the main actor before touching published state. The
/// CLI did the same job with a repainted terminal block; here the "live region"
/// is just the last entry of `entries`.
@MainActor
@Observable
final class SubtitleModel {
    /// Which side of the call an utterance came from. Both directions land on
    /// one timeline, so every entry has to say whose words it is showing.
    enum Direction: String, Hashable, Sendable, CaseIterable {
        /// The far end, captured from the process tap.
        case remote
        /// Us, captured from the microphone.
        case local

        @MainActor
        var label: String { t("direction.\(rawValue)") }

        var systemImage: String {
            switch self {
            case .remote: return "person.wave.2"
            case .local: return "mic"
            }
        }
    }

    /// What the session does with what it hears.
    ///
    /// The two modes share every part of the pipeline — the same capture, the
    /// same sockets, the same utterance state machine — and differ only in
    /// whether a translation is asked for. Transcription is therefore not a
    /// second implementation but the same one with the target language left
    /// off, which is why it can never drift out of step with translation.
    enum SessionMode: String, Hashable, Sendable, CaseIterable, Identifiable {
        /// Both sides translated into the other's language. The default.
        case translate
        /// Both sides written down in the language they were spoken in, with
        /// no translation requested and no speech synthesised.
        case transcribe

        var id: String { rawValue }

        @MainActor
        var label: String { t("mode.\(rawValue)") }

        var systemImage: String {
            switch self {
            case .translate: return "character.bubble"
            case .transcribe: return "text.alignleft"
            }
        }
    }

    /// Which sides of the call are captured at all.
    ///
    /// Both is the app's reason to exist, but each half is useful alone: the
    /// far end alone is the case where our own words need no subtitling and
    /// the microphone should stay shut — no prompt, no permission, no second
    /// socket — and our own side alone is not tied to a call at all, which is
    /// what makes it usable for a meeting or for talking to oneself.
    enum CaptureScope: String, Hashable, Sendable, CaseIterable, Identifiable {
        /// The far end and us. The default.
        case both
        /// The far end only, from the process tap.
        case remoteOnly
        /// Us only, from the microphone.
        case localOnly

        var id: String { rawValue }

        @MainActor
        var label: String { t("scope.\(rawValue)") }

        var systemImage: String {
            switch self {
            case .both: return "person.2.wave.2"
            case .remoteOnly: return "person.wave.2"
            case .localOnly: return "mic"
            }
        }

        /// Whether this scope captures the given direction.
        func captures(_ direction: Direction) -> Bool {
            switch self {
            case .both: return true
            case .remoteOnly: return direction == .remote
            case .localOnly: return direction == .local
            }
        }

        /// Whether the process tap is opened. Only the tap needs a live call,
        /// so this is also what decides whether the session waits for one.
        var needsCall: Bool { self != .localOnly }
    }

    /// How large the subtitle text is set.
    ///
    /// Subtitles are read at a glance and often from further away than the
    /// rest of the interface — the user is on a call, not at the keyboard.
    /// One fixed size therefore fits nobody, and the system's Dynamic Type
    /// does not reach a macOS app. The scale multiplies the transcript and
    /// translation only; headers, timestamps and chrome keep their own sizes
    /// so the card does not turn into a wall of large text.
    enum TranscriptSize: String, Hashable, Sendable, CaseIterable, Identifiable {
        case small
        case medium
        case large
        case extraLarge

        var id: String { rawValue }

        @MainActor
        var label: String { t("transcriptSize.\(rawValue)") }

        /// Point size of the line the reader is there for — the translation
        /// while translating, the transcript otherwise.
        ///
        /// Medium is 15 pt, the size macOS sets body text at, so the default
        /// board reads as part of the system rather than as a presentation
        /// surface. The other three step around it.
        var primary: CGFloat {
            switch self {
            case .small: return 13
            case .medium: return 15
            case .large: return 19
            case .extraLarge: return 24
            }
        }

        /// The source line above it. Kept proportionally closer to the primary
        /// at the large end: at 24 pt an 12 pt caption reads as a different
        /// document rather than as the same sentence.
        var secondary: CGFloat {
            switch self {
            case .small: return 11
            case .medium: return 12
            case .large: return 14
            case .extraLarge: return 17
            }
        }
    }

    /// One utterance. `transcript` is the source language, `translation` the
    /// target; both arrive as cumulative snapshots until `isComplete`.
    @Observable
    final class Entry: Identifiable, Equatable {
        let id = UUID()
        var direction: Direction = .remote
        var transcript: String = ""
        var translation: String = ""
        var isComplete = false

        /// When the utterance opened, not when it closed: what a reader
        /// scanning the board wants is when someone started speaking, and it
        /// is also the only one of the two that never moves once shown.
        let startedAt: Date

        /// Whether the entry directly above came from the same side.
        ///
        /// Stored rather than derived in the view from a neighbouring index:
        /// it only changes when an entry is added or removed, while the view
        /// redraws on every streamed delta. Keeping it here means a board of
        /// any length costs nothing per delta to lay out, and it is written
        /// in exactly one place — `liveEntry(_:)`, where the board grows.
        var continuesRun = false

        /// The complement, and the one the spacing reads: a card that opens a
        /// new speaker's run gets air above it. Not simply `!continuesRun` —
        /// the first card on the board starts no *new* run, so it takes no
        /// leading gap.
        var startsNewSpeaker = false

        init(
            direction: Direction = .remote,
            transcript: String = "",
            translation: String = "",
            isComplete: Bool = false,
            startedAt: Date = .now,
            continuesRun: Bool = false,
            startsNewSpeaker: Bool = false
        ) {
            self.direction = direction
            self.transcript = transcript
            self.translation = translation
            self.isComplete = isComplete
            self.startedAt = startedAt
            self.continuesRun = continuesRun
            self.startsNewSpeaker = startsNewSpeaker
        }

        static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.id == rhs.id
                && lhs.direction == rhs.direction
                && lhs.transcript == rhs.transcript
                && lhs.translation == rhs.translation
                && lhs.isComplete == rhs.isComplete
                && lhs.startedAt == rhs.startedAt
                && lhs.continuesRun == rhs.continuesRun
                && lhs.startsNewSpeaker == rhs.startsNewSpeaker
        }

        var isEmpty: Bool { transcript.isEmpty && translation.isEmpty }

        /// `HH:mm:ss` in the current locale, for the card header and the
        /// copied transcript. Formatted on read rather than stored, so a
        /// language switch relabels entries already on the board.
        var timeLabel: String {
            startedAt.formatted(
                .dateTime.hour(.twoDigits(amPM: .omitted)).minute().second()
            )
        }
    }

    enum Status: Equatable {
        case idle
        case waitingForCall
        case connecting
        case running
        case failed(String)

        /// Localized on read rather than stored, so a language switch
        /// relabels a status the model is already holding.
        @MainActor
        var label: String {
            switch self {
            case .idle: return t("status.idle")
            case .waitingForCall: return t("status.waitingForCall")
            case .connecting: return t("status.connecting")
            case .running: return t("status.running")
            case .failed(let message): return t("status.failed", message)
            }
        }
    }

    /// Why a start attempt failed before any audio flowed. The service's own
    /// errors arrive as text and stay as text; these are the app's own, so
    /// they carry a key and get localized at display time.
    enum StartFailure: String, Equatable, Sendable {
        case missingCredentials = "error.noCredentials"
        case unsupportedSystem = "error.unsupportedOS"
        case sameLanguages = "error.sameLanguages"

        @MainActor
        var message: String { t(rawValue) }
    }

    private(set) var entries: [Entry] = []
    private struct ArchivedEntry {
        let direction: Direction
        let transcript: String
        let translation: String
        let startedAt: Date
    }
    @ObservationIgnored private var archivedEntries: [ArchivedEntry] = []
    @ObservationIgnored private var liveEntries: [Direction: Entry] = [:]
    private static let residentEntryLimit = 500
    private static let renderedEntryLimit = 250

    var entryCount: Int { archivedEntries.count + entries.count }
    var visibleEntries: ArraySlice<Entry> { entries.suffix(Self.renderedEntryLimit) }
    private(set) var status: Status = .idle
    private(set) var callState: CallState = .idle
    private(set) var isRunning = false

    /// The mode the entries on the board were produced under, which is not
    /// necessarily the one `mode` now holds: the board outlives the session,
    /// and the preference can be changed once it has stopped.
    ///
    /// Views read this rather than `mode` when laying out an entry, so a board
    /// of transcripts does not start reserving room for translations the
    /// moment the user flips the picker back.
    private(set) var runningMode = Defaults.mode

    /// True while synthesised speech of our own translation is being played.
    /// Surfaced so the UI can show that the far end is currently hearing the
    /// translation rather than us.
    private(set) var isSpeaking = false

    /// Where the synthesised translation of our own speech is played. Empty
    /// means it is not played at all — subtitles only.
    ///
    /// Pointed at a loopback device that is *also* the system default input,
    /// this is what puts the translation on the call. That is the only setting
    /// in the app the user cannot be spared: the app can enumerate devices, but
    /// only the user knows which one they wired into the call.
    var outputDeviceUID = Defaults.outputDeviceUID {
        didSet { Defaults.outputDeviceUID = outputDeviceUID }
    }

    /// Which device our own speech is captured from. Empty follows the system
    /// default input.
    ///
    /// Worth setting precisely when `outputDeviceUID` points at a loopback
    /// device: that device is then the system default input, so following the
    /// default would capture our own synthesised translation instead of us.
    /// Naming the real microphone here is what makes the two coexist.
    var inputDeviceUID = Defaults.inputDeviceUID {
        didSet { Defaults.inputDeviceUID = inputDeviceUID }
    }

    /// Whether the far end hears our translation in our own voice rather than
    /// the stock one. Only the uplink can use this: it is the only direction
    /// whose speaker is us, and the only one that synthesises speech.
    var clonesVoice = Defaults.clonesVoice {
        didSet { Defaults.clonesVoice = clonesVoice }
    }

    /// The translation options outlive the session: a user who subtitles
    /// Japanese calls should not re-pick Japanese at every launch. They are
    /// small, non-secret preferences, so they live in defaults — the keychain
    /// holds the credentials and nothing else.
    ///
    /// Our language: what the far end gets translated *into*, and the language
    /// we are assumed to speak.
    ///
    /// A pick here is honoured as written. If it collides with the far end's
    /// language the far end takes the language this side just vacated, which is
    /// the swap the user would otherwise have done by hand — "I speak Japanese"
    /// when they were down as Japanese can only mean the pair was the wrong way
    /// round.
    ///
    /// That rewriting only applies while translating. Transcription has
    /// nothing to translate into, so two sides on the same language is a call
    /// between two speakers of it, and swapping would be undoing a deliberate
    /// choice.
    var myLanguage = Defaults.myLanguage {
        didSet {
            guard myLanguage != oldValue else { return }
            Defaults.myLanguage = myLanguage
            guard !isSwapping, translates, myLanguage == theirLanguage else { return }
            theirLanguage = oldValue
        }
    }

    /// The far end's language: what we get translated *into*, and the language
    /// they are assumed to speak.
    ///
    /// Both languages are always known, which is what makes the app a single
    /// two-field setup: with the pair in hand, both directions are fully
    /// determined and neither needs a switch of its own. Auto-detect used to be
    /// allowed here and bought nothing — it only made the reverse direction
    /// impossible, since there was then no language to translate into.
    var theirLanguage = Defaults.theirLanguage {
        didSet {
            guard theirLanguage != oldValue else { return }
            Defaults.theirLanguage = theirLanguage
            guard !isSwapping, translates, theirLanguage == myLanguage else { return }
            myLanguage = oldValue
        }
    }

    /// Swaps the two sides in one step.
    ///
    /// Done as two plain assignments this would pass through a state where both
    /// sides read the same language, tripping the collision rule above and
    /// leaving the pair somewhere the user did not ask for. The flag suspends
    /// that rule for the duration: a swap is a complete edit, never a
    /// half-finished one, so it needs no correcting.
    func swapLanguages() {
        let mine = myLanguage
        isSwapping = true
        myLanguage = theirLanguage
        theirLanguage = mine
        isSwapping = false
    }

    /// True only inside `swapLanguages()`. See the collision rule above.
    @ObservationIgnored private var isSwapping = false

    /// Puts the pair back to the one a fresh install starts from. Reachable
    /// from Settings because a pair can have been stored wrong by an older
    /// build, and correcting it one side at a time runs into the collision rule
    /// — the half-edited state is exactly what that rule rewrites.
    func resetLanguagesToDefault() {
        isSwapping = true
        myLanguage = Defaults.initialMyLanguage
        theirLanguage = Defaults.initialTheirLanguage
        isSwapping = false
    }

    /// Whether the pair is already the default one, so the reset control can
    /// say there is nothing to undo.
    var usesDefaultLanguagePair: Bool {
        myLanguage == Defaults.initialMyLanguage
            && theirLanguage == Defaults.initialTheirLanguage
    }

    /// Whether the session translates or only writes down what it hears.
    ///
    /// Stored like the language pair and for the same reason: someone who
    /// takes notes on calls rather than translating them is doing it again
    /// next launch.
    ///
    /// Switching to transcription does not rewrite the pair. The two
    /// languages stay exactly as they were, keep pinning ASR to a known
    /// language on each side, and are still there when the user switches
    /// back.
    var mode = Defaults.mode {
        didSet {
            guard mode != oldValue else { return }
            Defaults.mode = mode
            // Transcription allows a pair the other mode cannot run on, so
            // coming back from it can land on two identical languages. Left
            // alone that is a start that fails with an error the user has no
            // obvious way to clear — the pickers would both have to move, and
            // moving one trips the collision rule. Give the far end back the
            // language it had before the pair collapsed.
            guard translates, myLanguage == theirLanguage else { return }
            theirLanguage = myLanguage == Defaults.initialTheirLanguage
                ? Defaults.initialMyLanguage
                : Defaults.initialTheirLanguage
        }
    }

    /// Whether the current mode asks the service for a translation at all.
    var translates: Bool { mode == .translate }

    /// Which sides are captured. Stored for the same reason as the mode:
    /// someone who only ever subtitles the far end is doing it again next
    /// launch.
    var scope = Defaults.scope {
        didSet {
            guard scope != oldValue else { return }
            Defaults.scope = scope
        }
    }

    /// How large the subtitle text is set. A reading preference, not a session
    /// one, so unlike the mode and the pair it stays editable mid-call: the
    /// moment someone wants it bigger is the moment they are straining to read
    /// a live line.
    var transcriptSize = Defaults.transcriptSize {
        didSet {
            guard transcriptSize != oldValue else { return }
            Defaults.transcriptSize = transcriptSize
        }
    }

    /// Whether each card carries the time its utterance began.
    ///
    /// On by default: a transcript without times answers what was said but not
    /// when, which is the question anyone rereading a call afterwards has.
    /// Switchable because during the call itself it is one more thing on a
    /// line that is still being written.
    var showsTimestamps = Defaults.showsTimestamps {
        didSet {
            guard showsTimestamps != oldValue else { return }
            Defaults.showsTimestamps = showsTimestamps
        }
    }

    /// Whether the source line is shown under a translation.
    ///
    /// Only meaningful while translating — transcription has nothing but the
    /// source, so the view ignores this and always shows it. Off suits a user
    /// who does not read the far end's language at all and for whom the source
    /// is noise; on suits one checking the translation against it.
    var showsSourceText = Defaults.showsSourceText {
        didSet {
            guard showsSourceText != oldValue else { return }
            Defaults.showsSourceText = showsSourceText
        }
    }

    /// The scope the entries on the board were produced under. Pinned at
    /// `start()` alongside `runningMode`, and read by views for the same
    /// reason — the board outlives the session that filled it.
    private(set) var runningScope = Defaults.scope

    var region: TranslationClient.Config.Region = Defaults.region {
        didSet { Defaults.region = region }
    }

    /// Translating a language into itself would echo the speaker back at
    /// themselves, so the pair has to differ. This is the app's only
    /// precondition beyond credentials.
    ///
    /// Transcription has no such precondition: the two languages are then only
    /// telling each side's ASR what it is listening to, and a call where both
    /// sides speak the same language is the ordinary case rather than a
    /// mistake. So the requirement is the mode's, not the pair's.
    var hasUsableLanguagePair: Bool { !translates || myLanguage != theirLanguage }

    /// Whether our own translation is spoken aloud. Derived rather than stored:
    /// a chosen output device *is* the request to speak, and an empty one is
    /// the request not to. One fewer switch that can contradict another.
    ///
    /// Transcription produces no translation, so there is nothing for it to
    /// speak — the device stays chosen and comes back with translation rather
    /// than being cleared behind the user's back. Capturing the far end alone
    /// is the same story from the other direction: our own side is what gets
    /// synthesised, and it is not being captured.
    var speaksTranslation: Bool {
        translates && scope.captures(.local) && !outputDeviceUID.isEmpty
    }


    private var session: CallAudioSession?
    private var clients: [Direction: TranslationClient] = [:]
    @ObservationIgnored private var eventBatchers: [Direction: TranslationEventBatcher] = [:]
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    private let playbackPath = TranslationPlaybackPath()

    /// One per direction, held outside the actor because the Core Audio IO
    /// thread feeds audio in without hopping to the main actor — that hop would
    /// add latency and risk dropping buffers on a realtime thread.
    private let downlinkPath = AudioPath(direction: .remote)
    private let uplinkPath = AudioPath(direction: .local)


    // MARK: - lifecycle

    func start() {
        guard !isRunning else { return }
        guard #available(macOS 14.2, *) else {
            status = .failed(StartFailure.unsupportedSystem.message)
            return
        }
        // Translating a language into itself would echo the speaker back at
        // themselves; refuse rather than running a session that cannot work.
        // Transcription is exempt — see `hasUsableLanguagePair`.
        guard hasUsableLanguagePair else {
            status = .failed(StartFailure.sameLanguages.message)
            return
        }

        isRunning = true
        status = .connecting
        // Pinned for the session's lifetime. The picker is disabled while
        // running, but the entries already on the board were produced under
        // the mode that was current when they arrived, and the view reads this
        // rather than the live preference to decide how to lay them out.
        runningMode = mode
        runningScope = scope

        // Keychain and Core Audio device discovery can both synchronously
        // cross process boundaries. Keep that work away from the main actor so
        // pressing Start never stalls window input or the first animation.
        let inputUID = inputDeviceUID
        let outputUID = outputDeviceUID
        startupTask = Task { [weak self] in
            let prepared = await Task.detached(priority: .userInitiated) {
                (
                    CredentialStore.load(),
                    AudioInputDevice.named(uid: inputUID),
                    AudioOutputDevice.named(uid: outputUID)
                )
            }.value
            guard !Task.isCancelled, let self, self.isRunning else { return }
            self.startupTask = nil
            guard prepared.0.isComplete else {
                self.isRunning = false
                self.status = .failed(StartFailure.missingCredentials.message)
                return
            }
            self.startPrepared(
                credentials: prepared.0,
                inputDevice: prepared.1,
                outputDevice: prepared.2
            )
        }
    }

    private func startPrepared(
        credentials: CredentialStore.Credentials,
        inputDevice: AudioInputDevice?,
        outputDevice: AudioOutputDevice?
    ) {
        guard isRunning else { return }
        entries.removeAll()
        archivedEntries.removeAll()
        liveEntries.removeAll()

        // A socket is opened only for a side that is actually captured. The
        // unused one is not merely left idle: an open session with no audio
        // still costs a connection and would sit there waiting for speech
        // that can never arrive.
        //
        // Translating, the far end speaks theirs and is rendered into ours.
        // Transcribing, nothing is rendered into anything — the target is
        // dropped and the same socket returns only the transcript, still with
        // its source language pinned so ASR knows what it is hearing.
        if scope.captures(.remote) {
            let downlink = makeClient(
                direction: .remote,
                credentials: credentials,
                targetLanguage: translates ? myLanguage : nil,
                sourceLanguage: theirLanguage,
                wantsAudio: false
            )
            clients[.remote] = downlink
            downlinkPath.install(client: downlink)
            downlink.connect()
        }

        // The mirror image: we speak ours and are translated into theirs.
        // Audio is requested only when a device was chosen to play it into,
        // never while transcribing — there is no translation to speak — and
        // never when our own side is not captured in the first place.
        if scope.captures(.local) {
            let wantsAudio = speaksTranslation && startPlayer(device: outputDevice)
            let uplink = makeClient(
                direction: .local,
                credentials: credentials,
                targetLanguage: translates ? theirLanguage : nil,
                sourceLanguage: myLanguage,
                wantsAudio: wantsAudio,
                // One speaker — us — holds this stream for the whole call, so
                // cloning once and reusing the timbre is both enough and
                // steadier than re-cloning per reply.
                voice: clonesVoice && wantsAudio ? .cloneOnce : .preset
            )
            clients[.local] = uplink
            uplinkPath.install(client: uplink)
            uplink.connect()
        }

        let session = CallAudioSession()
        session.capturesUplink = scope.captures(.local)
        session.capturesDownlink = scope.captures(.remote)
        session.uplinkDevice = inputDevice
        session.onDownlink = { [weak self] buffer in
            self?.forward(tapBuffer: buffer)
        }
        session.onUplink = { [weak self] buffer in
            self?.forward(micBuffer: buffer)
        }
        session.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in self?.apply(callState: state) }
        }
        session.onError = { [weak self] error in
            Task { @MainActor [weak self] in self?.status = .failed("\(error)") }
        }
        self.session = session
        session.start()
        apply(callState: session.currentState)
    }

    /// Opens the playback engine, downgrading to subtitles-only rather than
    /// failing the whole session if the device cannot be opened — a missing
    /// BlackHole should not cost the user their subtitles.
    @discardableResult
    private func startPlayer(device: AudioOutputDevice?) -> Bool {
        let player = TranslationPlayer()
        player.onPlaybackChange = { [weak self] speaking in
            Task { @MainActor [weak self] in self?.isSpeaking = speaking }
        }
        do {
            try player.start(device: device)
            playbackPath.install(player)
            return true
        } catch {
            BridgeLog.audio.error(
                "translation playback unavailable: \("\(error)", privacy: .public)"
            )
            playbackPath.install(nil)
            return false
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        startupTask?.cancel()
        startupTask = nil
        session?.stop()
        session = nil
        for client in clients.values { client.close() }
        clients.removeAll()
        eventBatchers.removeAll()
        downlinkPath.install(client: nil)
        uplinkPath.install(client: nil)
        playbackPath.stop()
        isSpeaking = false
        status = .idle
        callState = .idle
        // `runningMode` deliberately survives: the entries it describes are
        // still on the board, and they are still what that mode produced.
    }

    /// Empties the board without touching the session, so a long call can be
    /// cleared down to the part worth reading.
    func clearEntries() {
        entries.removeAll()
        archivedEntries.removeAll()
        liveEntries.removeAll()
    }

    /// The whole board as text, source line above translation, for the copy
    /// button. Incomplete utterances are included: what is on screen is what
    /// lands on the clipboard.
    ///
    /// The time is always written, even when the board is hiding it: on screen
    /// it is a density choice, but pasted into notes the transcript has lost
    /// the running session that made "when" obvious.
    var transcriptText: String {
        let archived = archivedEntries.map { entry in
            transcriptBlock(
                direction: entry.direction,
                startedAt: entry.startedAt,
                transcript: entry.transcript,
                translation: entry.translation
            )
        }
        let resident = entries.map { entry in
            transcriptBlock(
                direction: entry.direction,
                startedAt: entry.startedAt,
                transcript: entry.transcript,
                translation: entry.translation
            )
        }
        return (archived + resident)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private func transcriptBlock(
        direction: Direction,
        startedAt: Date,
        transcript: String,
        translation: String
    ) -> String {
        let time = startedAt.formatted(
            .dateTime.hour(.twoDigits(amPM: .omitted)).minute().second()
        )
        let head = "[\(time)] \(direction.label)"
        return ([head, transcript, translation]
                .filter { !$0.isEmpty }
                .joined(separator: "\n"))
    }

    // MARK: - audio

    /// Called on the Core Audio IO thread, never on the main actor.
    @available(macOS 14.2, *)
    private nonisolated func forward(tapBuffer: DownlinkTap.Buffer) {
        downlinkPath.enqueue(tapBuffer)
    }

    /// Likewise on the microphone's IO thread.
    private nonisolated func forward(micBuffer: AVAudioPCMBuffer) {
        uplinkPath.enqueue(micBuffer)
    }

    private func apply(callState state: CallState) {
        callState = state
        guard isRunning else { return }
        // A failure reported by the capture side must survive the call-state
        // machine. Starting the tap can fail while the call itself is healthy,
        // and overwriting that with `.running` leaves the UI claiming to
        // subtitle a stream that never opened.
        if case .failed = status { return }
        // Capturing our own side alone never waits: the microphone is open
        // from the moment the session starts, so reporting "waiting for a
        // call" would describe a call this session does not need and will
        // never look for.
        guard runningScope.needsCall else {
            status = .running
            return
        }
        switch state {
        case .idle:
            status = .waitingForCall
        case .active:
            status = .running
        }
    }

    // MARK: - translation events

    private func makeClient(
        direction: Direction,
        credentials: CredentialStore.Credentials,
        targetLanguage: String?,
        sourceLanguage: String?,
        wantsAudio: Bool,
        voice: TranslationClient.Config.Voice = .preset
    ) -> TranslationClient {
        let config = TranslationClient.Config(
            apiKey: credentials.apiKey,
            workspaceID: credentials.workspaceID,
            region: region,
            targetLanguage: targetLanguage,
            sourceLanguage: sourceLanguage,
            wantsAudio: wantsAudio,
            voice: voice
        )
        let client = TranslationClient(config: config)
        let batcher = TranslationEventBatcher(
            label: "app.livetranslate.events.\(direction.rawValue)"
        ) { [weak self] events in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for event in events { self.handle(event, from: direction) }
            }
        } deliverAudio: { [playbackPath] data in
            if direction == .local { playbackPath.enqueue(data) }
        }
        eventBatchers[direction] = batcher
        client.onEvent = { [weak batcher] event in batcher?.submit(event) }
        return client
    }

    private func handle(_ event: TranslationClient.Event, from direction: Direction) {
        switch event {
        case .sessionReady:
            // The socket is up; what it is now waiting for depends on whether
            // this session needs a call. Capturing our own side alone does
            // not, and it is already capturing — saying "waiting for a call"
            // would leave that status on screen for the whole session.
            if case .connecting = status {
                status = runningScope.needsCall ? .waitingForCall : .running
            }
        case .transcript(let text):
            liveEntry(direction).transcript = text
            noteLiveTextChanged()
        case .transcriptDelta(let text):
            liveEntry(direction).transcript += text
            noteLiveTextChanged()
        case .transcriptComplete(let text):
            if !text.isEmpty { liveEntry(direction).transcript = text }
            noteLiveTextChanged()
            // Transcribing, this is the last event an utterance gets: no
            // translation follows, so nothing else would ever close the entry
            // and every later delta would append onto the same card. While
            // translating the seal is left to `translationComplete`, which
            // arrives after this one — sealing here would strand the
            // translation in a fresh entry of its own.
            if runningMode == .transcribe { seal(direction) }
        case .translation(let text):
            liveEntry(direction).translation = text
            noteLiveTextChanged()
        case .translationDelta(let text):
            liveEntry(direction).translation += text
            noteLiveTextChanged()
        case .translationComplete(let text):
            if !text.isEmpty { liveEntry(direction).translation = text }
            noteLiveTextChanged()
            seal(direction)
        case .audio(let pcm):
            // Only our own side is ever synthesised; the far end's translation
            // is read, not spoken, or we would talk over the call.
            if direction == .local { playbackPath.enqueue(pcm) }
        case .failed(let message):
            status = .failed(message)
        case .finished:
            seal(direction)
        case .speechStarted, .speechStopped:
            break
        }
    }

    /// Points the stored preferences at a throwaway defaults suite for the
    /// duration of a test, so a round-trip test cannot leave the real app's
    /// settings holding whatever the last case picked — both share this
    /// bundle's defaults domain when the tests run.
    ///
    /// Debug-only: nothing in the shipping app may redirect where the user's
    /// preferences are stored.
    #if DEBUG
    static func withTemporaryDefaults(_ body: () -> Void) {
        let name = "LiveTranslateBridgeTests.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: name) else { return body() }
        let previous = Defaults.store
        Defaults.store = suite
        defer {
            Defaults.store = previous
            suite.removePersistentDomain(forName: name)
        }
        body()
    }

    /// The defaults the preferences are currently read from, so a test can
    /// seed the raw keys an older build would have written.
    static var defaultsStoreForTesting: UserDefaults { Defaults.store }

    /// Fills the board with a short two-sided exchange, so the subtitle view
    /// can be previewed as it actually looks in use.
    ///
    /// The layout — the lanes, the measure, the grouping of consecutive turns,
    /// the source line under its translation — is only visible on a board with
    /// entries on it, and a real one needs credentials and a live call. An
    /// empty preview is how a board can look wrong for a whole release without
    /// anyone seeing it.
    ///
    /// The last entry is left open on purpose: the in-progress card has its
    /// own treatment, and it is the one on screen the most.
    func seedSampleBoard(mode: SessionMode = .translate) {
        runningMode = mode
        entries = [
            Entry(direction: .remote,
                  transcript: "Hi, thanks for taking the time today.",
                  translation: mode == .translate ? "嗨，感谢你今天抽出时间。" : "",
                  isComplete: true),
            Entry(direction: .remote,
                  transcript: "I wanted to walk through the proposal before we sign anything.",
                  translation: mode == .translate
                      ? "在签任何东西之前，我想先把方案过一遍。" : "",
                  isComplete: true),
            Entry(direction: .local,
                  transcript: "好的，我们先看第二部分的预算。",
                  translation: mode == .translate
                      ? "Sure, let's start with the budget in section two." : "",
                  isComplete: true),
            Entry(direction: .remote,
                  transcript: "That line item covers the whole quarter, not just the pilot.",
                  translation: mode == .translate
                      ? "那一项覆盖的是整个季度，而不只是试点阶段。" : "",
                  isComplete: false),
        ]
        archivedEntries.removeAll()
        liveEntries.removeAll()
        if let open = entries.last(where: { !$0.isComplete }) {
            liveEntries[open.direction] = open
        }
        // The board is built here in one go rather than grown through
        // `liveEntry`, so the run flags it would have written have to be
        // filled in after the fact — otherwise the preview shows a header on
        // every card and none of the grouping the layout is being checked for.
        for index in entries.indices { repairRunFlags(at: index) }
    }
    #endif

    /// Feeds one event through the utterance state machine without a socket.
    /// The event handling is the part worth testing; the transport is not.
    ///
    /// `mode` stands in for the one a real session would have pinned at
    /// `start()`, since these tests never open one.
    func ingestForTesting(
        _ event: TranslationClient.Event,
        from direction: Direction = .remote,
        mode: SessionMode = .translate,
        scope: CaptureScope = .both
    ) {
        runningMode = mode
        runningScope = scope
        handle(event, from: direction)
    }

    /// Puts the model into the state `start()` would leave it in, without
    /// opening a socket or touching Core Audio, so the status machine can be
    /// driven on its own. Status transitions are the part that differs
    /// per scope, and the part a unit test can otherwise never reach.
    func beginForTesting(mode: SessionMode = .translate, scope: CaptureScope = .both) {
        isRunning = true
        status = .connecting
        runningMode = mode
        runningScope = scope
    }

    /// Feeds one call-state change through the status machine.
    func applyForTesting(callState state: CallState) {
        apply(callState: state)
    }

    /// Entry currently being written to, appending a fresh one
    /// when the previous utterance from *this direction* has been sealed.
    ///
    /// The two directions interleave on one timeline, so the open entry for one
    /// side is not necessarily the last one on the board — the far end can start
    /// a sentence while ours is still streaming. Keeping a direct reference
    /// makes lookup O(1) and lets SwiftUI invalidate only this card.
    private func liveEntry(_ direction: Direction) -> Entry {
        if let entry = liveEntries[direction], !entry.isComplete { return entry }
        let entry = Entry(direction: direction)
        // The run flags are fixed the moment the card joins the board: what
        // sits above it never changes afterwards, because entries are only
        // ever appended here and removed by `seal` — which repairs them.
        if let previous = entries.last {
            entry.continuesRun = previous.direction == direction
            entry.startsNewSpeaker = previous.direction != direction
        }
        entries.append(entry)
        liveEntries[direction] = entry
        trimResidentEntries()
        return entry
    }

    /// Bumped whenever the live card's text grows, so the view can follow the
    /// bottom of the board without watching the text itself.
    ///
    /// Coalesced to one bump per run loop turn: the service sends deltas
    /// several times a second per direction, and each one that reached the
    /// view as a distinct change forced a scroll and a layout pass over the
    /// whole list. Batching them costs nothing visible — the scroll position
    /// can only change once per frame anyway — and takes the list's redraw
    /// cost off the critical path of an arriving word.
    private(set) var scrollTick = 0
    @ObservationIgnored private var isScrollTickScheduled = false

    private func noteLiveTextChanged() {
        guard !isScrollTickScheduled else { return }
        isScrollTickScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isScrollTickScheduled = false
            self.scrollTick &+= 1
        }
    }

    /// Marks that direction's current utterance done so the next event from it
    /// starts a new one.
    private func seal(_ direction: Direction) {
        guard let entry = liveEntries.removeValue(forKey: direction),
              let index = entries.firstIndex(where: { $0 === entry }) else { return }
        if entry.isEmpty {
            entries.remove(at: index)
            // The card that followed the removed one now has a different
            // neighbour above it, so its run flags describe a board that no
            // longer exists. Only that one card can be affected: everything
            // further down still has the same predecessor it always had.
            repairRunFlags(at: index)
            return
        }
        entry.isComplete = true
        trimResidentEntries()
    }

    /// Keeps observation and layout metadata bounded on multi-hour calls.
    /// Only completed prefix entries are archived, so a still-streaming turn
    /// is never detached from the card the user is watching.
    private func trimResidentEntries() {
        guard entries.count > Self.residentEntryLimit else { return }
        let batchSize = min(100, entries.count - Self.residentEntryLimit + 99)
        let completedPrefix = entries.prefix(batchSize).prefix { $0.isComplete }
        guard !completedPrefix.isEmpty else { return }
        archivedEntries.append(contentsOf: completedPrefix.map {
            ArchivedEntry(
                direction: $0.direction,
                transcript: $0.transcript,
                translation: $0.translation,
                startedAt: $0.startedAt
            )
        })
        entries.removeFirst(completedPrefix.count)
        repairRunFlags(at: 0)
    }

    /// Recomputes one entry's run flags against whatever now precedes it.
    private func repairRunFlags(at index: Int) {
        guard entries.indices.contains(index) else { return }
        guard index > 0 else {
            entries[index].continuesRun = false
            entries[index].startsNewSpeaker = false
            return
        }
        let previous = entries[index - 1].direction
        entries[index].continuesRun = previous == entries[index].direction
        entries[index].startsNewSpeaker = previous != entries[index].direction
    }
}
