import os
import AppKit
import Foundation

/// Streams 16 kHz PCM to Doubao simultaneous interpretation 2.0 (豆包同声传译
/// 2.0, Volcengine) and reports transcript, translation and — in
/// speech-to-speech mode — the translation spoken in the speaker's own
/// cloned voice.
///
/// Protocol: protobuf frames over one WebSocket; see `DoubaoProtocol`.
/// https://www.volcengine.com/docs/6561/1756902
///
/// Like `TranslationClient`, one client handles one direction, and it reports
/// through the same `TranslationClient.Event`s so the board, the audio router
/// and the recorder are shared.
///
/// The service has no item IDs. It does say where each sentence starts and
/// ends, separately for the source subtitle and for the translation, with
/// times on the source audio's clock. Each source sentence is one card, keyed
/// `seg-n` within the socket's session, and each translated sentence goes to
/// the card whose source it started under (see `beginTranslation`). A source
/// sentence folded into an earlier card's translation is closed when that
/// translation finishes, rather than left open for the rest of the call.
nonisolated final class DoubaoTranslationClient: NSObject, LiveTranslationSession, @unchecked Sendable {
    struct Config: Sendable {
        /// Console App ID. Empty selects the newer single API key login, in
        /// which `accessToken` is that key.
        var appID: String
        /// Access Token (with an App ID) or API Key (without one).
        var accessToken: String
        var resourceID: String = DoubaoTranslationClient.resourceID
        /// The language being spoken. The service does not detect it.
        var sourceLanguage: String
        /// nil transcribes: the service still needs a target, so one is
        /// picked and its translation discarded.
        var targetLanguage: String?
        /// Requests speech-to-speech, the translation spoken aloud.
        var wantsAudio: Bool
        var phrases: [String: String] = [:]
        var voice: TranslationClient.Config.Voice = .preset
        /// A stock speaker for `.preset`. Empty leaves the choice to the
        /// service, which clones the speaker.
        var presetSpeakerID: String = ""

        var mode: DoubaoProtocol.Mode {
            wantsAudio && targetLanguage != nil ? .speechToSpeech : .speechToText
        }

        /// What the service is asked to translate into.
        var effectiveTargetLanguage: String {
            targetLanguage ?? (sourceLanguage == "zh" ? "en" : "zh")
        }

        func startSession(id: String) -> DoubaoProtocol.StartSession {
            var start = DoubaoProtocol.StartSession(
                sessionID: id,
                userID: "livetranslate-bridge",
                mode: mode,
                sourceLanguage: sourceLanguage,
                targetLanguage: effectiveTargetLanguage,
                glossary: targetLanguage == nil ? [:] : phrases
            )
            if mode == .speechToSpeech {
                switch voice {
                case .cloned(let id):
                    start.speakerID = id
                    start.isCustomSpeaker = true
                case .cloneOnce, .cloneEachReply:
                    // No speaker: the service clones whoever is talking,
                    // continuously, which covers both frequencies.
                    break
                case .preset:
                    start.speakerID = presetSpeakerID
                }
            }
            return start
        }
    }

    static let url = URL(string: "wss://openspeech.bytedance.com/api/v4/ast/v2/translate")!
    static let resourceID = "volc.service_type.10053"

    /// Languages Seed LiveInterpret 2.0 translates between, among the ones
    /// the app offers. Korean and Russian are not among them.
    static let supportedLanguages: Set<String> = ["zh", "en", "ja", "fr", "de", "es", "pt", "id"]

    /// Read once, as in `TranslationClient`.
    private static let tracesFrames =
        ProcessInfo.processInfo.environment["CALLAUDIO_DEBUG"] != nil

    // Timings mirror `TranslationClient`'s; see there for how they were chosen.
    private static let pingInterval: TimeInterval = 5
    private static let pongTimeout: TimeInterval = 9
    private static let sweepInterval: TimeInterval = 5
    private static let maximumReconnectDelay: TimeInterval = 8
    private static let dormantAfter: TimeInterval = 10
    /// Two seconds at 16 kHz mono Int16.
    private static let replayBudgetBytes = 64_000

    private let config: Config
    private let diagnosticLabel: String
    private let urlSession: URLSession
    /// Every piece of mutable state below is touched only on this queue.
    private let queue = DispatchQueue(label: "app.livetranslate.doubao")
    private let stateLock = NSLock()
    private var failedFlag = false

    var onEvent: (@Sendable (TranslationClient.Event) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var sessionID = ""
    private var isStarted = false
    private var isRetired = false
    private var isClosing = false
    private var isDormant = false
    private var isReconnecting = false
    /// Never had a working session: a failure now is almost always the
    /// credentials or the account, which reconnecting cannot fix.
    private var everStarted = false
    private var reconnectAttempts = 0
    private var lastAudioAt = Date()
    private var lastPingAt = Date.distantPast
    private var pingOutstandingSince: Date?
    private var sweepTimer: DispatchSourceTimer?
    private var wakeObserver: NSObjectProtocol?

    /// Audio held until the session is started — before the first one, or
    /// across a reopen — trimmed to `replayBudgetBytes`, oldest first.
    private var heldAudio: [Data] = []
    private var heldBytes = 0

    /// One send in flight; audio queued behind a slow link is bounded.
    private var outbound: [(data: Data, audioBytes: Int, generation: Int)] = []
    private var sendInFlight = false

    private var readyWaiters: [CheckedContinuation<Bool, Never>] = []
    private var finishWaiter: CheckedContinuation<Void, Never>?

    // Segment state, reset with every socket.
    private var sourceSegment = 0
    /// The card the current (or last) translated sentence went to.
    private var translationTarget = 0
    private var sourceText = ""
    private var translationText = ""
    private var sourceOpen = false
    private var translationOpen = false
    /// Source sentences finished without a translation of their own yet.
    private var untranslated: [Int] = []
    /// When each recent source sentence started, on the source audio clock.
    private var sourceStarts: [(segment: Int, startMS: Int32)] = []
    /// Completed translation text per recent card, for a sentence that was
    /// translated in more than one part.
    private var settledTranslations: [Int: String] = [:]

    init(config: Config, diagnosticLabel: String = "unspecified") {
        self.config = config
        self.diagnosticLabel = diagnosticLabel
        let callbackQueue = OperationQueue()
        callbackQueue.name = "app.livetranslate.doubao.websocket"
        callbackQueue.maxConcurrentOperationCount = 1
        let configuration = URLSessionConfiguration.default
        configuration.networkServiceType = .responsiveData
        configuration.waitsForConnectivity = false
        urlSession = URLSession(
            configuration: configuration, delegate: nil, delegateQueue: callbackQueue
        )
        super.init()
    }

    var isFailed: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return failedFlag
    }

    private func setFailed(_ value: Bool) {
        stateLock.lock(); failedFlag = value; stateLock.unlock()
    }

    // MARK: - lifecycle

    func connect() {
        queue.async { [self] in
            guard task == nil, !isRetired else { return }
            lastAudioAt = Date()
            open()
            startSweepTimer()
            let wake = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
            ) { [weak self] _ in
                self?.queue.async { self?.drop(reason: "system woke from sleep") }
            }
            wakeObserver = wake
        }
    }

    private func open() {
        var request = URLRequest(url: Self.url)
        request.timeoutInterval = 30
        if config.appID.isEmpty {
            request.setValue(config.accessToken, forHTTPHeaderField: "X-Api-Key")
        } else {
            request.setValue(config.appID, forHTTPHeaderField: "X-Api-App-Key")
            request.setValue(config.accessToken, forHTTPHeaderField: "X-Api-Access-Key")
        }
        request.setValue(config.resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")

        let task = urlSession.webSocketTask(with: request)
        self.task = task
        generation &+= 1
        sessionID = UUID().uuidString
        isStarted = false
        isDormant = false
        pingOutstandingSince = nil
        lastPingAt = Date()
        resetSegments()
        setFailed(false)

        BridgeLog.socket.notice(
            "[\(self.diagnosticLabel, privacy: .public)] connecting to doubao ast v2 (\(self.config.mode.rawValue, privacy: .public) \(self.config.sourceLanguage, privacy: .public)→\(self.config.effectiveTargetLanguage, privacy: .public))"
        )
        task.resume()
        receive(generation: generation)
        // Ahead of everything else on the new socket.
        outbound.removeAll { $0.generation != generation }
        outbound.insert(
            (DoubaoProtocol.startSession(config.startSession(id: sessionID)), 0, generation),
            at: 0
        )
        pump()
    }

    func waitUntilReady(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            queue.async { [self] in
                if isStarted { continuation.resume(returning: true); return }
                if isRetired || (isFailed && !isReconnecting) {
                    continuation.resume(returning: false); return
                }
                readyWaiters.append(continuation)
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.resolveReady(false)
                }
            }
        }
    }

    private func resolveReady(_ ready: Bool) {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: ready) }
    }

    func finish() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                guard isStarted, task != nil else { continuation.resume(); return }
                isClosing = true
                finishWaiter = continuation
                enqueue(DoubaoProtocol.finishSession(sessionID: sessionID), audioBytes: 0)
                queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.resolveFinish() }
            }
        }
        close()
    }

    private func resolveFinish() {
        finishWaiter?.resume()
        finishWaiter = nil
    }

    func close() {
        queue.async { [self] in
            isRetired = true
            isClosing = true
            setFailed(true)
            sweepTimer?.cancel()
            sweepTimer = nil
            if let wakeObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            }
            wakeObserver = nil
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            outbound.removeAll()
            heldAudio.removeAll()
            heldBytes = 0
            resolveReady(false)
            resolveFinish()
            urlSession.invalidateAndCancel()
        }
    }

    /// Ends the current socket and, unless retired, opens another.
    private func drop(reason: String) {
        guard !isRetired, !isClosing, task != nil else { return }
        BridgeLog.socket.notice(
            "[\(self.diagnosticLabel, privacy: .public)] doubao socket dropped: \(reason, privacy: .public)"
        )
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isStarted = false
        setFailed(true)
        guard everStarted else {
            fail("Doubao rejected the session before it started: \(reason)")
            return
        }
        scheduleReconnect(reason: reason)
    }

    private func scheduleReconnect(reason: String, immediately: Bool = false) {
        guard !isRetired, !isReconnecting else { return }
        if !immediately, Date().timeIntervalSince(lastAudioAt) >= Self.dormantAfter {
            isDormant = true
            reconnectAttempts = 0
            BridgeLog.socket.notice(
                "[\(self.diagnosticLabel, privacy: .public)] no audio for \(Int(Self.dormantAfter))s; leaving the doubao socket closed until speech resumes"
            )
            return
        }
        isReconnecting = true
        reconnectAttempts += 1
        let delay = immediately ? 0 : min(
            Self.maximumReconnectDelay, pow(2, Double(reconnectAttempts - 1)) * 0.25
        )
        BridgeLog.socket.notice(
            "[\(self.diagnosticLabel, privacy: .public)] reconnecting in \(String(format: "%.2f", delay), privacy: .public)s (attempt \(self.reconnectAttempts, privacy: .public)): \(reason, privacy: .public)"
        )
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.isReconnecting = false
            guard !self.isRetired, self.task == nil else { return }
            self.open()
        }
    }

    /// Retires the session with a message the user sees.
    private func fail(_ message: String) {
        BridgeLog.socket.error(
            "[\(self.diagnosticLabel, privacy: .public)] doubao failed: \(message, privacy: .public)"
        )
        emit(.failed(message))
        close()
    }

    private func startSweepTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.sweepInterval,
                       repeating: Self.sweepInterval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.sweep() }
        sweepTimer = timer
        timer.resume()
    }

    /// Pings the live socket and reopens one that stopped answering.
    private func sweep() {
        guard !isRetired, !isClosing, let task else { return }
        let now = Date()
        if let since = pingOutstandingSince {
            if now.timeIntervalSince(since) >= Self.pongTimeout {
                drop(reason: "no pong for \(Int(Self.pongTimeout))s")
            }
            return
        }
        guard now.timeIntervalSince(lastPingAt) >= Self.pingInterval else { return }
        lastPingAt = now
        pingOutstandingSince = now
        let pinged = generation
        task.sendPing { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard pinged == self.generation else { return }
                if let error {
                    self.drop(reason: "ping failed: \(error.localizedDescription)")
                } else {
                    self.pingOutstandingSince = nil
                }
            }
        }
    }

    // MARK: - sending

    func sendAudio(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        queue.async { [self] in
            guard !isRetired else { return }
            lastAudioAt = Date()
            guard isStarted, task != nil else {
                hold(pcm)
                if isDormant {
                    isDormant = false
                    scheduleReconnect(reason: "audio resumed", immediately: true)
                }
                return
            }
            enqueue(DoubaoProtocol.audioChunk(sessionID: sessionID, pcm: pcm),
                    audioBytes: pcm.count)
        }
    }

    private func hold(_ pcm: Data) {
        heldAudio.append(pcm)
        heldBytes += pcm.count
        while heldBytes > Self.replayBudgetBytes, !heldAudio.isEmpty {
            heldBytes -= heldAudio.removeFirst().count
        }
    }

    private func enqueue(_ data: Data, audioBytes: Int) {
        if audioBytes > 0 {
            // Oldest audio goes first on a backlog: it is the part nobody is
            // waiting for any more.
            var queued = outbound.reduce(0) { $0 + $1.audioBytes }
            while queued + audioBytes > Self.replayBudgetBytes,
                  let stale = outbound.firstIndex(where: { $0.audioBytes > 0 }) {
                queued -= outbound[stale].audioBytes
                outbound.remove(at: stale)
            }
        }
        outbound.append((data, audioBytes, generation))
        pump()
    }

    private func pump() {
        guard !sendInFlight else { return }
        outbound.removeAll { $0.generation != generation }
        guard !outbound.isEmpty, let task else { return }
        // Taken off the queue as it goes out, so a reopen that rebuilds the
        // queue underneath an in-flight send cannot lose its start frame.
        let next = outbound.removeFirst()
        sendInFlight = true
        let sent = next.generation
        task.send(.data(next.data)) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.sendInFlight = false
                if let error, sent == self.generation, !self.isClosing {
                    self.drop(reason: "send failed: \(error.localizedDescription)")
                    return
                }
                self.pump()
            }
        }
    }

    // MARK: - receiving

    private func receive(generation: Int) {
        guard generation == self.generation, let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard generation == self.generation else { return }
                switch result {
                case .failure(let error):
                    if self.isClosing { self.setFailed(true); self.resolveFinish(); return }
                    self.drop(reason: "receive failed: \(error.localizedDescription)")
                case .success(let message):
                    switch message {
                    case .data(let data): self.handle(frame: data)
                    case .string(let text): self.handle(text: text)
                    @unknown default: break
                    }
                    self.receive(generation: generation)
                }
            }
        }
    }

    /// A text frame is the gateway's own error, sent as JSON before it closes.
    private func handle(text: String) {
        BridgeLog.socket.error(
            "[\(self.diagnosticLabel, privacy: .public)] doubao text frame: \(String(text.prefix(600)), privacy: .public)"
        )
        handleServiceError(text)
    }

    private func handle(frame: Data) {
        let response: DoubaoProtocol.Response
        do {
            response = try DoubaoProtocol.decodeResponse(frame)
        } catch {
            BridgeLog.socket.error(
                "[\(self.diagnosticLabel, privacy: .public)] undecodable doubao frame: \(String(describing: error), privacy: .public)"
            )
            return
        }
        if Self.tracesFrames {
            let line = "<< doubao event=\(response.event) status=\(response.statusCode) text=\(response.text.prefix(200)) audio=\(response.data.count)B"
            FileHandle.standardError.write(Data((line + "\n").utf8))
            BridgeLog.socket.notice("\(line, privacy: .public)")
        }
        apply(response)
    }

    /// Maps one decoded frame onto the shared events. Internal so the tests
    /// can drive it with frames built by `encodeResponseForTesting`.
    func apply(_ response: DoubaoProtocol.Response) {
        if response.isError {
            handleServiceError("\(response.statusCode): \(response.message)")
            return
        }
        guard let kind = response.kind else {
            BridgeLog.socket.notice("unhandled doubao event: \(response.event, privacy: .public)")
            return
        }
        let translates = config.targetLanguage != nil
        switch kind {
        case .sessionStarted:
            isStarted = true
            everStarted = true
            reconnectAttempts = 0
            emit(.streamStarted(sessionID))
            emit(.sessionReady)
            resolveReady(true)
            let carried = heldAudio
            heldAudio.removeAll()
            heldBytes = 0
            for chunk in carried {
                enqueue(DoubaoProtocol.audioChunk(sessionID: sessionID, pcm: chunk),
                        audioBytes: chunk.count)
            }

        case .sessionFinished:
            closeOpenSegments()
            emit(.finished)
            resolveFinish()
            if !isClosing {
                // The service ended an idle session on its own.
                task?.cancel(with: .goingAway, reason: nil)
                task = nil
                isStarted = false
                scheduleReconnect(reason: "service finished the session")
            }

        case .sessionFailed, .sessionCanceled:
            handleServiceError(response.message.isEmpty
                ? "session \(kind == .sessionFailed ? "failed" : "canceled")"
                : response.message)

        case .sourceSubtitleStart:
            beginSource(at: response.startTime)
        case .sourceSubtitleResponse:
            if !sourceOpen { beginSource(at: response.startTime) }
            sourceText = Self.merge(sourceText, response.text)
            if !sourceText.isEmpty { emit(.transcript(sourceText), segment: sourceSegment) }
        case .sourceSubtitleEnd:
            if !sourceOpen { beginSource(at: response.startTime) }
            sourceText = Self.merge(sourceText, response.text)
            endSource(at: response.endTime, translates: translates)

        case .translationSubtitleStart:
            guard translates else { break }
            beginTranslation(at: response.startTime)
        case .translationSubtitleResponse:
            guard translates else { break }
            if !translationOpen { beginTranslation(at: response.startTime) }
            translationText = Self.merge(translationText, response.text)
            if !translationText.isEmpty { emitTranslation(complete: false) }
        case .translationSubtitleEnd:
            guard translates else { break }
            if !translationOpen { beginTranslation(at: response.startTime) }
            translationText = Self.merge(translationText, response.text)
            endTranslation()

        case .ttsResponse:
            if !response.data.isEmpty { emit(.audio(response.data)) }
        case .ttsSentenceEnd:
            emit(.audioComplete)
        case .ttsSentenceStart, .usageResponse, .audioMuted:
            break

        case .startSession, .finishSession, .taskRequest, .updateConfig:
            break
        }
    }

    private func beginSource(at startMS: Int32) {
        if sourceOpen { endSource(at: startMS, translates: config.targetLanguage != nil) }
        sourceSegment += 1
        sourceText = ""
        sourceOpen = true
        if startMS > 0 { sourceStarts.append((sourceSegment, startMS)) }
        emit(.speechStarted, segment: sourceSegment, audioMS: Int(startMS))
    }

    private func endSource(at endMS: Int32, translates: Bool) {
        guard sourceOpen else { return }
        sourceOpen = false
        emit(.speechStopped, segment: sourceSegment, audioMS: Int(endMS))
        emit(.transcriptComplete(sourceText), segment: sourceSegment)
        // Speech stopped is what lets the player catch up on a backlog.
        emit(.speechStopped)
        if translates, sourceSegment > translationTarget { untranslated.append(sourceSegment) }
    }

    /// Picks the card a new translated sentence belongs to.
    ///
    /// When the frame is timed on the source audio's clock, that is the last
    /// source sentence to have started by then; a translation that spans two
    /// source sentences thus lands on the first, and one source sentence
    /// translated in two parts keeps both on its card. Without usable timing
    /// it is simply the next card. Either way it never moves backwards.
    private func beginTranslation(at startMS: Int32) {
        if translationOpen { endTranslation() }
        var card = translationTarget + 1
        if startMS > 0, let first = sourceStarts.first, let last = sourceStarts.last,
           startMS + 300 >= first.startMS, startMS <= last.startMS + 5_000 {
            let timed = sourceStarts.last { $0.startMS <= startMS + 300 }?.segment ?? card
            card = max(timed, translationTarget, 1)
        }
        translationTarget = card
        translationText = ""
        translationOpen = true
        untranslated.removeAll { $0 == card }
    }

    /// Reports the card's translation: what earlier parts already settled on
    /// it, followed by the part now streaming.
    ///
    /// A card whose translation was already completed only accepts a further
    /// completion, so a second part streams as repeated completions.
    private func emitTranslation(complete: Bool) {
        let settled = settledTranslations[translationTarget] ?? ""
        let text = Self.join(settled, translationText, language: config.effectiveTargetLanguage)
        if complete || !settled.isEmpty {
            emit(.translationComplete(text), segment: translationTarget)
        } else {
            emit(.translation(text), segment: translationTarget)
        }
        if complete { settledTranslations[translationTarget] = text }
    }

    private func endTranslation() {
        guard translationOpen else { return }
        translationOpen = false
        emitTranslation(complete: true)
        // Source sentences the translation went past without one of their
        // own were folded into an earlier card; close theirs.
        let folded = untranslated.filter { $0 < translationTarget }
        untranslated.removeAll { $0 < translationTarget }
        for segment in folded { emit(.responseFinished("completed"), segment: segment) }
        // Only the last few cards can still be reached by a later part.
        settledTranslations = settledTranslations.filter { $0.key >= translationTarget - 4 }
        if sourceStarts.count > 64 { sourceStarts.removeFirst(sourceStarts.count - 64) }
    }

    private func closeOpenSegments() {
        if sourceOpen { endSource(at: 0, translates: config.targetLanguage != nil) }
        if translationOpen { endTranslation() }
    }

    private func resetSegments() {
        sourceSegment = 0
        translationTarget = 0
        sourceText = ""
        translationText = ""
        sourceOpen = false
        translationOpen = false
        untranslated.removeAll()
        sourceStarts.removeAll()
        settledTranslations.removeAll()
    }

    /// Two parts of one translated sentence. Chinese and Japanese are
    /// written without spaces between them.
    static func join(_ first: String, _ second: String, language: String) -> String {
        guard !first.isEmpty else { return second }
        guard !second.isEmpty else { return first }
        return first + (["zh", "ja"].contains(language) ? "" : " ") + second
    }

    /// Joins a subtitle frame onto the sentence so far. The service sends
    /// growing snapshots on some paths and bare increments on others, so a
    /// frame that already contains the text is taken as the new whole and
    /// anything else is appended.
    static func merge(_ current: String, _ incoming: String) -> String {
        guard !incoming.isEmpty else { return current }
        if current.isEmpty || incoming.hasPrefix(current) { return incoming }
        if current.hasSuffix(incoming) || current.hasPrefix(incoming) { return current }
        return current + incoming
    }

    private func handleServiceError(_ message: String) {
        let lowered = message.lowercased()
        let fatal = [
            "auth", "unauthorized", "forbidden", "invalid", "permission", "denied",
            "quota", "arrear", "insufficient", "not found", "resource", "license",
            "45000", "unsupported",
        ]
        if !everStarted || fatal.contains(where: { lowered.contains($0) }) {
            fail("Doubao: \(message)")
            return
        }
        drop(reason: "service error: \(message)")
    }

    // MARK: - events

    private func emit(_ event: TranslationClient.Event) {
        onEvent?(event)
    }

    private func emit(_ event: TranslationClient.Event, segment: Int, audioMS: Int? = nil) {
        let identity = TranslationClient.EventIdentity(
            streamID: sessionID, itemID: "seg-\(segment)", audioMS: audioMS
        )
        onEvent?(.identified(identity, event))
    }

    #if DEBUG
    /// Runs `apply` on the client's queue, as a socket frame would.
    func applyForTesting(_ response: DoubaoProtocol.Response) {
        queue.sync { apply(response) }
    }

    func markStartedForTesting() {
        queue.sync { everStarted = true; isStarted = true }
    }
    #endif
}
