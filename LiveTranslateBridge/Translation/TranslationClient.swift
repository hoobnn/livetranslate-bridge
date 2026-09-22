import os
import Foundation

/// Streams 16 kHz PCM to Alibaba Model Studio's live translation model and
/// reports transcript and translation as they arrive.
///
/// Protocol: qwen3.8 for both preset and cloned voices; voice settings never
/// change the model or silently fall back to an older protocol.
/// https://help.aliyun.com/zh/model-studio/qwen3-8-livetranslate-flash-realtime
///
/// One client handles one direction. A call needs two: the far end translated
/// into the user's language, and the user translated into the far end's.
nonisolated public final class TranslationClient: NSObject, @unchecked Sendable {
    public struct Config: Sendable {
        public var apiKey: String
        public var workspaceID: String
        public var region: Region
        /// Language to translate into, e.g. "zh", "en". See the model's
        /// supported-language table.
        ///
        /// nil omits the translation configuration. Callers may display only
        /// ASR, but omission does not disable the service's default translation.
        public var targetLanguage: String?
        /// qwen3.5 source language; qwen3.8 always detects it automatically.
        public var sourceLanguage: String?
        /// Synthesised speech of the translation. Off by default: playing it
        /// during a call feeds back into the microphone.
        public var wantsAudio: Bool
        /// Term overrides, source term to preferred translation.
        public var phrases: [String: String]
        /// Whose voice the synthesised translation speaks in. Only has an
        /// effect when `wantsAudio` is on, since it is the audio it shapes.
        public var voice: Voice
        /// qwen3.5 VAD controls. qwen3.8 uses its independent speaker detection
        /// schema and does not consume this legacy pause window.
        public var segmentation: Segmentation

        /// When the service closes an utterance and starts translating it.
        ///
        /// Server VAD closes a turn after the configured silence window.
        /// Streaming output may arrive before then. A short window can split
        /// ordinary breathing pauses and remove context from each translation.
        public struct Segmentation: Sendable, Equatable {
            /// The silence that ends an utterance. The service accepts
            /// 200–6000 ms.
            public var silenceDuration: Int
            /// Service-side VAD sensitivity. This is not the per-second PCM
            /// peak shown in diagnostics and must not be converted to dBFS.
            public var threshold: Double

            /// The service's own defaults, sent explicitly so the wire config
            /// says what the session actually runs on.
            public static let serviceDefault = Segmentation(
                silenceDuration: 1_000, threshold: 0.2
            )

            /// Explicit low-latency option. Natural breathing and hesitation can
            /// exceed this; it does not guarantee a semantically complete sentence.
            public static let responsive = Segmentation(
                silenceDuration: 400, threshold: 0.2
            )

            /// Longer pauses in narrated lessons and long-form speech.
            public static let listening = Segmentation(
                silenceDuration: 1_500, threshold: 0.2
            )

            public init(silenceDuration: Int, threshold: Double) {
                self.silenceDuration = min(max(silenceDuration, 200), 6_000)
                self.threshold = min(max(threshold, -1), 1)
            }

            var payload: [String: Any] {
                [
                    "type": "server_vad",
                    "threshold": threshold,
                    "silence_duration_ms": silenceDuration,
                ]
            }
        }

        /// The service can speak the translation in the speaker's own voice
        /// rather than a stock one.
        ///
        /// Available through q3.5's session schema. q3.8 uses a different
        /// schema and does not document live voice cloning.
        public enum Voice: Sendable, Equatable {
            /// The stock voice, `Tina`. No clone fields are sent at all.
            case preset
            /// Clone once at the top of the session and reuse that timbre.
            /// Suits one speaker holding the floor.
            case cloneOnce
            /// Re-clone before every reply, so the timbre tracks whoever is
            /// currently talking. Suits two or more speakers on one stream.
            case cloneEachReply
            /// A timbre cloned ahead of time through the voice-cloning API,
            /// named by its `qwen-translate-vc-…` ID.
            case cloned(id: String)

            /// The `frequency` the service expects, or nil for `.preset`,
            /// which sends no clone configuration.
            var frequency: String? {
                switch self {
                case .preset: return nil
                case .cloneOnce: return "once"
                case .cloneEachReply: return "always"
                case .cloned: return "never"
                }
            }

            /// The `voice` field. Server-side cloning requires the literal
            /// `default`; a pre-cloned timbre names itself.
            var name: String? {
                switch self {
                case .preset: return nil
                case .cloneOnce, .cloneEachReply: return "default"
                case .cloned(let id): return id
                }
            }
        }

        public enum Region: String, Sendable {
            case beijing = "cn-beijing"
            case singapore = "ap-southeast-1"
        }

        public init(
            apiKey: String,
            workspaceID: String,
            region: Region = .beijing,
            targetLanguage: String?,
            sourceLanguage: String? = nil,
            wantsAudio: Bool = false,
            phrases: [String: String] = [:],
            voice: Voice = .preset,
            segmentation: Segmentation = .serviceDefault
        ) {
            self.segmentation = segmentation
            self.apiKey = apiKey
            self.workspaceID = workspaceID
            self.region = region
            self.targetLanguage = targetLanguage
            self.sourceLanguage = sourceLanguage
            self.wantsAudio = wantsAudio
            self.phrases = phrases
            self.voice = voice
        }

        var modelID: String { TranslationClient.model }

        var sessionUpdate: [String: Any] {
            var translation: [String: Any]?
            if let targetLanguage {
                translation = ["language": targetLanguage]
                if !phrases.isEmpty {
                    translation?["corpus"] = ["phrases": phrases]
                }
            }

            var session: [String: Any] = [
                "output_modalities": wantsAudio ? ["text", "audio"] : ["text"],
                "audio": ["input": ["turn_detection": [
                    "type": "speaker_detection", "threshold": 0.5,
                ]]],
            ]
            if let translation { session["translation"] = translation }
            if wantsAudio, let frequency = voice.frequency, let name = voice.name {
                session["voice"] = name
                var audio = session["audio"] as? [String: Any] ?? [:]
                audio["output"] = ["voice": name]
                session["audio"] = audio
                session["enable_voice_clone"] = true
                session["voice_clone_options"] = ["frequency": frequency]
            }
            // qwen3.8 ASR is always enabled and detects the source language.
            // Do not send legacy input_audio_transcription / turn_detection.
            return session
        }

        var url: URL {
            var components = URLComponents()
            components.scheme = "wss"
            components.host = "\(workspaceID).\(region.rawValue).maas.aliyuncs.com"
            components.path = "/api-ws/v1/realtime"
            components.queryItems = [
                URLQueryItem(name: "model", value: modelID)
            ]
            return components.url!
        }
    }

    public static let model = "qwen3.8-livetranslate-flash-realtime"

    public struct EventIdentity: Sendable, Hashable {
        public var streamID: String
        public var itemID: String?
        public var responseID: String?
        public var audioMS: Int?
        public init(streamID: String, itemID: String? = nil, responseID: String? = nil, audioMS: Int? = nil) {
            self.streamID = streamID; self.itemID = itemID
            self.responseID = responseID; self.audioMS = audioMS
        }
    }

    public enum Event: Sendable {
        indirect case identified(EventIdentity, Event)
        case itemLinked(output: String, source: String)
        case responseFinished(String)
        case responseOpened
        case streamStarted(String)

        var payload: Event {
            if case .identified(_, let event) = self { return event.payload }
            return self
        }

        /// Cumulative source-language transcript; replaces what came before.
        /// Only older models emit this; q3.8 sends `transcriptDelta`.
        case transcript(String)
        /// True incremental source-language transcript, appended to what came
        /// before.
        case transcriptDelta(String)
        /// Final source-language transcript for one utterance.
        case transcriptComplete(String)
        /// Cumulative translation; replaces what came before. Only older models
        /// emit this; q3.8 sends `translationDelta`.
        case translation(String)
        /// True incremental translation text, appended to what came before.
        case translationDelta(String)
        /// Final translation for one utterance.
        case translationComplete(String)
        /// Synthesised audio, 24 kHz mono Int16, only when `wantsAudio`.
        case audio(Data)
        case audioComplete
        case speechStarted
        case speechStopped
        case sessionReady
        case finished
        case failed(String)
    }

    /// Mutable only so a session can fall back to the stock voice when the
    /// service rejects the cloned one; see `handleServiceError`. Every other
    /// field is fixed for the client's lifetime.
    private let diagnosticLabel: String
    private var itemLinks = ServerItemLinks()
    private var streamID = UUID().uuidString
    private var receivedEventIDs = Set<String>()
    private var eventIDOrder: [String] = []
    private var config: Config
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private let lock = NSLock()
    private var isOpen = false
    private var sawSessionUpdated = false
    private var pendingAudio: [Data] = []
    private var pendingAudioBytes = 0
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var readyContinuations: [CheckedContinuation<Bool, Never>] = []
    private var readyCallbacks: [@Sendable (Bool) -> Void] = []
    private var finishCallbacks: [@Sendable () -> Void] = []
    private var isDead = false
    /// Set once teardown starts. The socket errors out on the parked
    /// `receive` as soon as it is cancelled, which is expected rather than a
    /// failure worth reporting.
    private var isClosing = false

    // MARK: - reconnection

    /// True once `close()` was called, so nothing reopens the socket behind
    /// the caller's back. `isDead` cannot serve this: a socket that dropped on
    /// its own is dead too, and that is precisely the case worth reopening.
    private var isRetired = false

    /// How many times the socket has been reopened without a working session
    /// in between. Reset the moment `session.updated` lands, so a call that
    /// drops once an hour never walks up the backoff ladder.
    private var reconnectAttempts = 0

    /// Which socket a callback belongs to.
    ///
    /// Cancelling a replaced socket makes its parked `receive` fail, and that
    /// failure arrives *after* the new socket is already installed. Without a
    /// generation to check against, the old socket's dying breath would be
    /// read as the new one failing and tear it straight back down — an
    /// endless reconnect loop that only shows up once a reconnect happens.
    private var generation = 0

    /// Set while a reopen is scheduled or in flight, so a burst of failures —
    /// the parked `receive` and an in-flight `send` both error on the same
    /// drop — reopens once rather than racing two sockets onto one stream.
    private var isReconnecting = false

    /// When the socket last heard from the service. A silent call still
    /// produces frames, so a gap here means the connection is gone rather
    /// than that nobody is talking.
    private var lastInboundAt = Date()

    /// Audio handed over while the socket was down, replayed once the new one
    /// is configured. One second is enough to cover a reopen without letting
    /// a long outage push stale speech into the call.
    private var reconnectBuffer: [Data] = []
    private var reconnectBufferedBytes = 0

    /// Reopen after this long without a single inbound frame. The service
    /// closes an idle session on its own, and the drop is not always reported
    /// as a socket error — see `sweepIfStalled()`.
    ///
    /// Held well above the service's own quiet stretch. It routinely goes
    /// 20-25 seconds without a frame on a live call and then resumes on its
    /// own, so a shorter window spends the call reconnecting through healthy
    /// silence — and every reopen costs a handshake, drops most of a second
    /// of queued speech, and invalidates the server-side voice clone.
    private static let inboundTimeout: TimeInterval = 40

    /// How often the idle check runs. Well under `inboundTimeout` so the
    /// detection latency is bounded by the timeout rather than by the tick.
    private static let sweepInterval: TimeInterval = 5

    /// Ceiling on the backoff, so a service outage retries forever at a
    /// sane rate rather than either hammering it or giving up on the call.
    private static let maximumReconnectDelay: TimeInterval = 8

    /// At 16 kHz mono Int16 one second is 32000 bytes. Bounds the replay
    /// buffer by duration rather than by chunk count, which varies with the
    /// capture device's buffer size.
    private static let reconnectBufferBytes = 32_000

    /// WebSocketTask accepts concurrent sends, but unconstrained sends turn a
    /// brief network stall into hundreds of live completion handlers. A
    /// single pump preserves ordering and makes the in-flight bound explicit.
    private struct OutboundMessage: @unchecked Sendable {
        let text: String
        let task: URLSessionWebSocketTask
        let generation: Int
        /// PCM bytes this message carries, 0 for anything that is not audio.
        /// The encoded frame is a third larger and JSON-wrapped, so it cannot
        /// stand in for the duration the budget is really about.
        let audioBytes: Int

        var isAudio: Bool { audioBytes > 0 }
    }
    /// How much audio may sit queued behind a slow send before the oldest is
    /// dropped.
    ///
    /// Expressed in bytes rather than in messages because the caller chooses
    /// the chunk size: counting messages made the real tolerance a second of
    /// speech at 100 ms chunks and four tenths at 40 ms, so shortening the
    /// chunks to cut latency would have quietly shortened the network
    /// tolerance too. One second at 16 kHz mono Int16 is the same second
    /// either way.
    private static let outboundAudioBudget = 32_000
    private let outboundQueue = DispatchQueue(label: "call-audio-bridge.outbound")
    private var outboundMessages: [OutboundMessage] = []
    private var outboundHead = 0
    private var outboundInFlight = false

    private var sweepTimer: DispatchSourceTimer?
    private let sweepQueue = DispatchQueue(label: "call-audio-bridge.keepalive")

    public var onEvent: (@Sendable (Event) -> Void)?
    #if DEBUG
    /// Opt-in protocol trace for deterministic file replay; never enabled by UI.
    var onRawFrameForTesting: (@Sendable (String) -> Void)?
    #endif

    /// True once the socket has failed or been closed; callers should stop
    /// sending audio.
    public var isFailed: Bool {
        lock.lock(); defer { lock.unlock() }
        return isDead
    }

    /// Callback form of `waitUntilReady`, for synchronous callers such as a
    /// plain `main.swift` where Swift concurrency is not running.
    public func whenReady(
        timeout: TimeInterval = 15,
        _ completion: @escaping @Sendable (Bool) -> Void
    ) {
        if let settled = readyStateNow() { completion(settled); return }
        lock.lock()
        readyCallbacks.append(completion)
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            [weak self] in
            self?.resumeReady(false)
        }
    }

    /// Callback form of `finish`, for the same reason.
    public func finish(_ completion: @escaping @Sendable () -> Void) {
        guard isRunningNow else { close(); completion(); return }
        lock.lock()
        finishCallbacks.append(completion)
        lock.unlock()
        send(["type": "session.finish"])
        beginClosing()
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.resumeFinish()
        }
    }

    /// Waits for `session.updated`. Returns false if the connection failed
    /// first, so a caller can abort instead of streaming into a dead socket.
    public func waitUntilReady(timeout: TimeInterval = 15) async -> Bool {
        if let settled = readyStateNow() { return settled }

        return await withCheckedContinuation {
            (continuation: CheckedContinuation<Bool, Never>) in
            lock.lock()
            let settled = sawSessionUpdated || isDead
            let ready = sawSessionUpdated
            if !settled { readyContinuations.append(continuation) }
            lock.unlock()
            if settled { continuation.resume(returning: ready); return }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                [weak self] in
                self?.resumeReady(false)
            }
        }
    }

    /// Returns the already-settled result, or nil if the caller must wait.
    private func readyStateNow() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        if sawSessionUpdated { return true }
        if isDead { return false }
        return nil
    }

    private func resumeReady(_ ready: Bool) {
        lock.lock()
        let waiting = readyContinuations
        let callbacks = readyCallbacks
        readyContinuations.removeAll()
        readyCallbacks.removeAll()
        lock.unlock()
        for continuation in waiting { continuation.resume(returning: ready) }
        for callback in callbacks { callback(ready) }
    }

    /// Marks the session as winding down so the socket errors that follow a
    /// deliberate close are not reported as failures.
    private func beginClosing() {
        lock.lock()
        isClosing = true
        lock.unlock()
    }

    private var isClosingNow: Bool {
        lock.lock(); defer { lock.unlock() }
        return isClosing
    }

    /// The live configuration, read under the socket lifecycle lock.
    private var currentConfig: Config {
        lock.lock(); defer { lock.unlock() }
        return config
    }

    /// Marks the socket unusable, and — unless the caller retired it — asks
    /// for a new one.
    ///
    /// `reason` is nil for a deliberate teardown, where the death is the
    /// point and there is nothing to recover.
    private func markDead(reason: String? = nil) {
        lock.lock()
        let alreadyDead = isDead
        isDead = true
        let retired = isRetired
        lock.unlock()
        guard !alreadyDead else { return }
        resumeReady(false)
        resumeFinish()
        guard let reason, !retired else { return }
        scheduleReconnect(reason: reason)
    }

    public init(config: Config, diagnosticLabel: String = "unspecified") {
        self.diagnosticLabel = diagnosticLabel
        self.config = config
        super.init()
    }

    // MARK: - lifecycle

    public func connect() {
        lock.lock()
        guard task == nil, !isRetired else { lock.unlock(); return }
        openLocked()
        lock.unlock()
        startSweepTimer()
    }

    /// Builds and resumes the socket. The caller holds `lock`, because a
    /// reopen has to swap the task in the same critical section that cleared
    /// the old one — otherwise audio arriving in between sees `task == nil`
    /// and is dropped rather than queued.
    private func openLocked() {
        var request = URLRequest(url: config.url)
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let callbackQueue = OperationQueue()
        callbackQueue.name = "call-audio-bridge.websocket"
        callbackQueue.maxConcurrentOperationCount = 1
        let session = URLSession(
            configuration: .default, delegate: nil, delegateQueue: callbackQueue
        )
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        // A fresh socket starts from a clean slate in every respect that
        // decides whether audio flows: nothing is configured yet, nothing has
        // failed yet, and the idle clock starts now rather than carrying the
        // dead socket's last frame time into the new one.
        isOpen = false
        isDead = false
        isClosing = false
        sawSessionUpdated = false
        lastInboundAt = Date()
        generation &+= 1
        let opened = generation

        let host = config.url.host ?? "?"
        BridgeLog.socket.notice("connecting to \(host, privacy: .public)")
        task.resume()
        // Both reach for `lock` themselves, so they run after the caller has
        // released it. Hopping off keeps `openLocked` free of a re-entrant
        // lock while still ordering them after the task is installed.
        sweepQueue.async { [weak self] in
            guard let self else { return }
            self.receiveNext(generation: opened)
            self.sendSessionUpdate()
        }
    }

    /// Whether `generation` is still the live socket. A callback from an
    /// older one is reporting a socket that has already been replaced.
    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == self.generation
    }

    /// Reopens the socket after a drop, unless the caller has retired it.
    ///
    /// The service closes a session that has gone quiet, and a call has quiet
    /// stretches by nature — nobody speaks for a minute, the socket goes, and
    /// from the audio side nothing looks wrong: capture still runs, buffers
    /// still convert, and `sendAudio` still accepts them. The result is a
    /// session that has silently stopped subtitling while claiming to run.
    /// Reopening is what makes a pause in the conversation survivable.
    private func scheduleReconnect(reason: String) {
        lock.lock()
        guard !isRetired, !isReconnecting else { lock.unlock(); return }
        isReconnecting = true
        reconnectAttempts += 1
        let attempt = reconnectAttempts
        lock.unlock()

        // Exponential, capped: the first retry is immediate enough to be
        // invisible in conversation, and a service that is genuinely down is
        // not hammered.
        let delay = min(
            Self.maximumReconnectDelay,
            pow(2, Double(attempt - 1)) * 0.25
        )
        BridgeLog.socket.notice(
            "reconnecting in \(String(format: "%.2f", delay), privacy: .public)s (attempt \(attempt, privacy: .public)): \(reason, privacy: .public)"
        )

        sweepQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard !self.isRetired else {
                self.isReconnecting = false
                self.lock.unlock()
                return
            }
            // Drop the old socket before opening the new one: its parked
            // `receive` would otherwise keep a second stream alive.
            let stale = self.task
            self.task = nil
            self.session = nil
            self.openLocked()
            self.isReconnecting = false
            self.lock.unlock()
            stale?.cancel(with: .goingAway, reason: nil)
        }
    }

    /// Reopens a socket that has gone quiet without erroring.
    ///
    /// A dropped connection does not always surface as a `receive` failure:
    /// the service can stop answering while the socket stays nominally open,
    /// and the parked `receive` then waits forever. Inbound frames are the
    /// only reliable liveness signal, because the service emits them
    /// throughout a session rather than only when someone speaks.
    private func sweepIfStalled() {
        lock.lock()
        let idle = Date().timeIntervalSince(lastInboundAt)
        // A socket that is gone or dead is the case most in need of the
        // sweep, not the case to skip: the paths that end a socket without
        // reopening — a service error, a second failure arriving after
        // `markDead` already ran, a reconnect refused mid-flight — leave a
        // session that captures audio, converts it, and streams it nowhere.
        // Requiring a live task here is what let a dead lane stay dead for a
        // whole call while every other signal looked healthy.
        let stranded = task == nil || isDead
        // `isClosing` covers the `finish()` window, where the caller is
        // winding the session down but has not retired it yet. Reopening
        // there would race a new socket against the drain.
        let shouldSweep = !isRetired && !isClosing && !isReconnecting
            && (stranded || idle >= Self.inboundTimeout)
        lock.unlock()
        guard shouldSweep else { return }
        scheduleReconnect(
            reason: stranded
                ? "socket went away without reopening"
                : "no inbound frame for \(Int(idle))s"
        )
    }

    /// Decides what a service `error` frame means for the session.
    ///
    /// The service reports fatal and transient conditions through the same
    /// event, and the socket is closed underneath either way. Reporting every
    /// one as `.failed` retires the whole session at the UI, which is how a
    /// single recoverable 400 used to end subtitling for the rest of a call
    /// while audio capture carried on feeding a socket nobody would reopen.
    private func handleServiceError(_ message: String) {
        // A missing cloned voice must be visible. Never silently change the
        // requested voice or switch model to make an unsuccessful clone look OK.
        if currentConfig.wantsAudio, currentConfig.voice.frequency != nil,
           isMissingClonedVoice(message) {
            onEvent?(.failed(message))
            close()
            return
        }

        guard isRecoverable(message) else {
            // Retire it: a bad key or an unreachable model is not going to
            // resolve itself, and the idle sweep would otherwise keep
            // reopening the socket to collect the same rejection forever.
            onEvent?(.failed(message))
            close()
            return
        }

        BridgeLog.socket.notice(
            "service error is recoverable; reopening rather than failing the session"
        )
        markDead(reason: "service error: \(message)")
    }

    /// Whether the service is rejecting a cloned voice it can no longer find.
    private func isMissingClonedVoice(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("voice")
            && (lowered.contains("could not be found")
                || lowered.contains("not found"))
    }

    /// Whether reopening the socket stands a chance of clearing the error.
    ///
    /// Deliberately a denylist of the conditions a reconnect cannot fix —
    /// bad credentials, a model the account cannot reach, exhausted quota.
    /// Anything else is treated as transient, because the cost of retrying a
    /// genuinely fatal error is a bounded backoff loop, while the cost of
    /// giving up on a transient one is the rest of the call.
    private func isRecoverable(_ message: String) -> Bool {
        let lowered = message.lowercased()
        let fatal = [
            "invalidapikey", "invalid api key", "unauthorized", "forbidden",
            "authenticationerror", "accessdenied", "permissiondenied",
            "model not found", "modelnotfound", "invalidaccesskeyid",
            "arrearage", "quota", "insufficient",
        ]
        return !fatal.contains { lowered.contains($0) }
    }

    private func startSweepTimer() {
        lock.lock()
        guard sweepTimer == nil, !isRetired else { lock.unlock(); return }
        let timer = DispatchSource.makeTimerSource(queue: sweepQueue)
        timer.schedule(
            deadline: .now() + Self.sweepInterval,
            repeating: Self.sweepInterval,
            leeway: .milliseconds(500)
        )
        timer.setEventHandler { [weak self] in self?.sweepIfStalled() }
        sweepTimer = timer
        lock.unlock()
        timer.resume()
    }

    /// Records that the service is still talking to us. Called for every
    /// inbound frame, including the routine ones the parser ignores.
    private func noteInbound() {
        lock.lock()
        lastInboundAt = Date()
        lock.unlock()
    }

    /// Sends `session.finish` and waits for `session.finished` before closing.
    /// The service drops the last utterance if the socket closes without it.
    public func finish() async {
        guard isRunningNow else { close(); return }

        send(["type": "session.finish"])
        beginClosing()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            storeFinishContinuation(continuation)

            // The server normally answers in well under a second; this bounds
            // a hang rather than setting an expected wait.
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.resumeFinish()
            }
        }
        close()
    }

    public func close() {
        lock.lock()
        let task = self.task
        let timer = sweepTimer
        self.task = nil
        self.session = nil
        sweepTimer = nil
        isOpen = false
        isDead = true
        isClosing = true
        // Retiring is what distinguishes this from a dropped socket: the
        // caller is done, so nothing may reopen it. A reconnect already in
        // flight checks this flag before swapping a new task in.
        isRetired = true
        sawSessionUpdated = false
        pendingAudio.removeAll()
        pendingAudioBytes = 0
        reconnectBuffer.removeAll()
        reconnectBufferedBytes = 0
        lock.unlock()
        outboundQueue.async { [weak self] in
            self?.outboundMessages.removeAll()
            self?.outboundHead = 0
        }
        timer?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
    }

    private var isRunningNow: Bool {
        lock.lock()
        defer { lock.unlock() }
        return task != nil && isOpen
    }

    private func storeFinishContinuation(
        _ continuation: CheckedContinuation<Void, Never>
    ) {
        lock.lock()
        finishContinuation = continuation
        lock.unlock()
    }

    private func resumeFinish() {
        lock.lock()
        let continuation = finishContinuation
        let callbacks = finishCallbacks
        finishContinuation = nil
        finishCallbacks.removeAll()
        lock.unlock()
        continuation?.resume()
        for callback in callbacks { callback() }
    }

    // MARK: - sending

    private func sendSessionUpdate() {
        let config = currentConfig
        let sessionConfig = config.sessionUpdate
        let keys = sessionConfig.keys.sorted().joined(separator: ",")
        BridgeLog.socket.notice(
            "session.update \(config.modelID, privacy: .public) sending keys: \(keys, privacy: .public)"
        )
        // Named on its own line because it is the one setting whose effect
        // the user feels on every subtitle, and the one most worth checking
        // against what `session.updated` echoes back.
        BridgeLog.socket.notice(
            "segmentation requested: audio.input.turn_detection=speaker_detection threshold=0.5"
        )
        send(["type": "session.update", "session": sessionConfig])
    }

    /// Queues audio until the session is configured; the service rejects
    /// `input_audio_buffer.append` sent before `session.updated`.
    ///
    /// Audio that arrives between a drop and the reopened session is held in
    /// `reconnectBuffer` rather than discarded, so the sentence being spoken
    /// across the gap is still translated once the new socket is configured.
    public func sendAudio(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        lock.lock()
        // No socket and not coming back: the client is retired, so this is
        // capture outliving the session by a buffer or two rather than a
        // fault worth reporting.
        guard !isRetired else { lock.unlock(); return }

        // Mid-reconnect. Keep the most recent second and let the rest go:
        // what matters is not losing the words spoken across the gap, and
        // audio older than that arrives too late to be worth translating.
        guard task != nil, !isDead else {
            reconnectBuffer.append(pcm)
            reconnectBufferedBytes += pcm.count
            while reconnectBufferedBytes > Self.reconnectBufferBytes,
                  !reconnectBuffer.isEmpty {
                reconnectBufferedBytes -= reconnectBuffer.removeFirst().count
            }
            lock.unlock()
            return
        }

        if !sawSessionUpdated {
            // One second by bytes, not by device-dependent callback count.
            pendingAudio.append(pcm)
            pendingAudioBytes += pcm.count
            var dropped = false
            while pendingAudioBytes > Self.reconnectBufferBytes,
                  !pendingAudio.isEmpty {
                pendingAudioBytes -= pendingAudio.removeFirst().count
                dropped = true
            }
            let depth = pendingAudioBytes
            let shouldLog = dropped && noteQueueFullLocked()
            lock.unlock()
            // A handshake that never lands looks exactly like a working
            // capture from the audio side, so say it out loud — but once a
            // second, not once per buffer: at ten buffers a second the log
            // itself otherwise becomes the problem.
            if shouldLog {
                BridgeLog.socket.error(
                    "handshake audio queue capped at \(depth, privacy: .public) bytes; discarding oldest audio"
                )
            }
            return
        }
        lock.unlock()
        appendAudio(pcm)
    }

    /// Whether the queue-full line is due again. Caller holds `lock`.
    private func noteQueueFullLocked() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastQueueFullLog) >= 1 else { return false }
        lastQueueFullLog = now
        return true
    }

    private var lastQueueFullLog = Date.distantPast

    private func appendAudio(_ pcm: Data) {
        send([
            "type": "input_audio_buffer.append",
            "audio": pcm.base64EncodedString(),
        ], audioBytes: pcm.count)
    }

    private func flushPendingAudio() {
        lock.lock()
        let queued = pendingAudio
        pendingAudio.removeAll()
        pendingAudioBytes = 0
        lock.unlock()
        for chunk in queued { appendAudio(chunk) }
    }

    private func send(_ payload: [String: Any], audioBytes: Int = 0) {
        lock.lock()
        let task = self.task
        let generation = self.generation
        lock.unlock()
        guard let task,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        let message = OutboundMessage(
            text: text, task: task, generation: generation,
            audioBytes: audioBytes
        )
        outboundQueue.async { [weak self] in
            guard let self else { return }
            if audioBytes > 0 {
                // The in-flight message is excluded: it is already with the
                // socket and cannot be taken back.
                let start = self.outboundHead + (self.outboundInFlight ? 1 : 0)
                var queued = self.outboundMessages[start...]
                    .reduce(0) { $0 + $1.audioBytes }
                // Drop from the front until the new chunk fits. Oldest first,
                // because on a backlog the stale audio is the part nobody is
                // waiting for any more.
                while queued + audioBytes > Self.outboundAudioBudget {
                    guard let stale = self.outboundMessages[start...]
                        .firstIndex(where: \.isAudio) else { break }
                    queued -= self.outboundMessages[stale].audioBytes
                    self.outboundMessages.remove(at: stale)
                }
            }
            self.outboundMessages.append(message)
            self.pumpOutbound()
        }
    }

    private func pumpOutbound() {
        guard !outboundInFlight else { return }
        while outboundHead < outboundMessages.count,
              !isCurrent(outboundMessages[outboundHead].generation) {
            outboundHead += 1
        }
        guard outboundHead < outboundMessages.count else {
            outboundMessages.removeAll(keepingCapacity: true)
            outboundHead = 0
            return
        }
        let message = outboundMessages[outboundHead]
        outboundInFlight = true
        message.task.send(.string(message.text)) { [weak self] error in
            guard let self else { return }
            self.outboundQueue.async {
                self.outboundInFlight = false
                self.outboundHead += 1
                if self.outboundHead >= 64,
                   self.outboundHead * 2 >= self.outboundMessages.count {
                    self.outboundMessages.removeFirst(self.outboundHead)
                    self.outboundHead = 0
                }
                if let error { self.handleSendFailure(error, generation: message.generation) }
                self.pumpOutbound()
            }
        }
    }

    private func handleSendFailure(_ error: Error, generation: Int) {
            // As in `receiveNext`: a send that failed on a socket already
            // replaced is reporting the old connection's death, not the new
            // one's.
        guard isCurrent(generation) else { return }
        guard !isClosingNow else { markDead(); return }
        BridgeLog.socket.error(
            "send failed: \(error.localizedDescription, privacy: .public)"
        )
        // Not reported as a session failure: the socket is about to be
        // reopened, and a red status for a drop the user never notices would
        // be worse than the drop.
        markDead(reason: "send failed: \(error.localizedDescription)")
    }

    // MARK: - receiving

    private func receiveNext(generation: Int) {
        lock.lock()
        let task = generation == self.generation ? self.task : nil
        lock.unlock()
        guard let task else { return }

        task.receive { [weak self] result in
            guard let self else { return }
            // A callback from a socket that has already been replaced says
            // nothing about the one now carrying the call. Cancelling the old
            // socket is what produced this, so treating it as a live failure
            // would tear down its healthy replacement.
            guard self.isCurrent(generation) else { return }
            switch result {
            case .failure(let error):
                guard !self.isClosingNow else { self.markDead(); return }
                BridgeLog.socket.error(
                    "receive failed: \(error.localizedDescription, privacy: .public)"
                )
                self.markDead(reason: "receive failed: \(error.localizedDescription)")
            case .success(let message):
                // Any frame at all proves the connection is alive, including
                // the routine ones `handle` ignores.
                self.noteInbound()
                switch message {
                case .string(let text):
                    self.handle(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handle(text)
                    }
                @unknown default:
                    break
                }
                self.receiveNext(generation: generation)
            }
        }
    }

    private func handle(_ text: String) {
        #if DEBUG
        onRawFrameForTesting?(text)
        #endif
        if ProcessInfo.processInfo.environment["CALLAUDIO_DEBUG"] != nil {
            // stderr is invisible in a GUI app, so mirror it to the log where
            // a running session can actually be read.
            let frame = String(text.prefix(600))
            FileHandle.standardError.write(Data("<< \(frame)\n".utf8))
            BridgeLog.socket.notice("<< \(frame, privacy: .public)")
        }
        guard let data = text.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let type = event["type"] as? String else { return }

        func delta() -> String { event["delta"] as? String ?? "" }
        func transcriptText() -> String {
            event["transcript"] as? String ?? event["text"] as? String ?? ""
        }

        if let id = event["event_id"] as? String {
            guard receivedEventIDs.insert(id).inserted else { return }
            eventIDOrder.append(id)
            if eventIDOrder.count > 4096 { receivedEventIDs.remove(eventIDOrder.removeFirst()) }
        }
        let identity = EventIdentity(streamID: streamID,
            itemID: event["item_id"] as? String,
            responseID: event["response_id"] as? String,
            audioMS: (event["audio_start_ms"] ?? event["audio_end_ms"]) as? Int)
        func emit(_ value: Event) {
            // Never discard server identity. Events missing IDs keep the legacy
            // path for compatibility; they are not guessed onto a known turn.
            if identity.itemID != nil || identity.responseID != nil {
                onEvent?(.identified(identity, value))
            } else { onEvent?(value) }
        }

        for link in itemLinks.observe(type: type, event: event) {
            onEvent?(.identified(.init(streamID: streamID, itemID: link.output),
                .itemLinked(output: link.output, source: link.source)))
            BridgeLog.socket.notice("[\(self.diagnosticLabel, privacy: .public)] verified segment link stream=\(self.streamID, privacy: .public) output=\(link.output, privacy: .public) source=\(link.source, privacy: .public)")
        }
        switch type {
        case "conversation.item.created", "response.output_item.added", "response.output_item.done":
            break // Metadata is classified above; role alone is insufficient.
        case "response.done":
            if let response = event["response"] as? [String: Any], let id = response["id"] as? String {
                let status = response["status"] as? String ?? "unknown"
                let outputs = response["output"] as? [[String: Any]] ?? []
                for item in outputs {
                    guard let itemID = item["id"] as? String else { continue }
                    let context = EventIdentity(streamID: streamID, itemID: itemID, responseID: id)
                    for part in item["content"] as? [[String: Any]] ?? [] {
                        if let value = (part["transcript"] ?? part["text"]) as? String, !value.isEmpty {
                            onEvent?(.identified(context, .translationComplete(value)))
                        }
                    }
                    onEvent?(.identified(context, .responseFinished(status)))
                }
                onEvent?(.identified(.init(streamID: streamID, responseID: id), .responseFinished(status)))
                BridgeLog.socket.notice("[\(self.diagnosticLabel, privacy: .public)] response ended stream=\(self.streamID, privacy: .public) id=\(id, privacy: .public) status=\(status, privacy: .public)")
            }
        case "response.created":
            if let response = event["response"] as? [String: Any], let id = response["id"] as? String {
                onEvent?(.identified(.init(streamID: streamID, responseID: id), .responseOpened))
            }
        case "response.content_part.added", "response.content_part.done",
             "input_audio_buffer.committed", "rate_limits.updated":
            // Named individually so the catch-all below stays meaningful:
            // these are routine and carry nothing the subtitles need.
            BridgeLog.socket.notice("server event: \(type, privacy: .public)")

        case "session.created":
            itemLinks = ServerItemLinks()
            streamID = ((event["session"] as? [String: Any])?["id"] as? String) ?? UUID().uuidString
            receivedEventIDs.removeAll(); eventIDOrder.removeAll()
            if let id = event["event_id"] as? String {
                receivedEventIDs.insert(id); eventIDOrder.append(id)
            }
            onEvent?(.streamStarted(streamID))
            // Purely informational: the configuration that matters is the one
            // `session.update` sends back. Logged because its echo of the
            // server defaults is the reference for what we must not drop.
            let defaults = (event["session"] as? [String: Any])
                .map { $0.keys.sorted().joined(separator: ",") } ?? "?"
            BridgeLog.socket.notice(
                "session.created; server session keys: \(defaults, privacy: .public)"
            )

        case "session.updated":
            if currentConfig.wantsAudio, let frequency = currentConfig.voice.frequency {
                let session = event["session"] as? [String: Any]
                let audio = session?["audio"] as? [String: Any]
                let output = audio?["output"] as? [String: Any]
                let options = session?["voice_clone_options"] as? [String: Any]
                guard session?["enable_voice_clone"] as? Bool == true,
                      options?["frequency"] as? String == frequency,
                      output?["voice"] as? String == currentConfig.voice.name else {
                    onEvent?(.failed("qwen3.8 did not confirm the requested voice-clone configuration"))
                    close()
                    return
                }
                BridgeLog.socket.notice("qwen3.8 voice clone configuration echoed; audio similarity still requires listening")
            }
            let acceptedSession = event["session"] as? [String: Any] ?? [:]
            let audio = acceptedSession["audio"] as? [String: Any]
            let input = audio?["input"] as? [String: Any]
            let accepted = input?["turn_detection"] as? [String: Any]
            let requestedType = "speaker_detection"
            if let accepted {
                let detectionType = accepted["type"] as? String ?? "unknown"
                let silence = (accepted["silence_duration_ms"] as? Int).map(String.init) ?? "not reported"
                BridgeLog.socket.notice("[\(self.diagnosticLabel, privacy: .public)] segmentation echoed: model=\(currentConfig.modelID, privacy: .public) type=\(detectionType, privacy: .public) silence_ms=\(silence, privacy: .public)")
                if detectionType != requestedType {
                    BridgeLog.socket.error("service segmentation type differs from request")
                }
            } else {
                BridgeLog.socket.error("service did not echo the model-specific segmentation configuration")
            }
            lock.lock()
            isOpen = true
            sawSessionUpdated = true
            // A working session clears the ladder, so the next drop — which
            // on a long call is a separate incident, not a continuation of
            // this one — retries promptly again.
            let wasReconnect = reconnectAttempts > 0
            reconnectAttempts = 0
            // Audio held across the gap goes in front of whatever queued
            // behind the handshake, so the utterance stays in order.
            let carried = reconnectBuffer
            reconnectBuffer.removeAll()
            reconnectBufferedBytes = 0
            pendingAudio.insert(contentsOf: carried, at: 0)
            pendingAudioBytes += carried.reduce(0) { $0 + $1.count }
            while pendingAudioBytes > Self.reconnectBufferBytes,
                  !pendingAudio.isEmpty {
                pendingAudioBytes -= pendingAudio.removeFirst().count
            }
            let queued = pendingAudio.count
            lock.unlock()
            BridgeLog.socket.notice(
                "session.updated; flushing \(queued, privacy: .public) queued buffers\(wasReconnect ? " (after reconnect, \(carried.count) carried)" : "", privacy: .public)"
            )
            emit(.sessionReady)
            resumeReady(true)
            flushPendingAudio()

        case "conversation.item.input_audio_transcription.delta":
            // q3.8's transcript path: a true delta, unlike the `.text`
            // snapshots the older models send.
            let value = delta()
            if !value.isEmpty { emit(.transcriptDelta(value)) }

        case "conversation.item.input_audio_transcription.text":
            // Confirmed text plus the still-changing tail; both are cumulative
            // snapshots, so they replace rather than append.
            let confirmed = event["text"] as? String ?? ""
            let stash = event["stash"] as? String ?? ""
            let value = confirmed + stash
            if !value.isEmpty { emit(.transcript(value)) }

        case "conversation.item.input_audio_transcription.completed":
            let value = transcriptText()
            emit(.transcriptComplete(value))

        case "conversation.item.input_audio_transcription.failed":
            emit(.failed("transcription failed: \(text)"))

        case "response.text.delta", "response.audio_transcript.delta":
            // True deltas, unlike the snapshot events below.
            let value = delta()
            if !value.isEmpty { emit(.translationDelta(value)) }

        case "response.text.text", "response.audio_transcript.text":
            let confirmed = event["text"] as? String ?? ""
            let stash = event["stash"] as? String ?? ""
            let value = confirmed + stash
            if !value.isEmpty { emit(.translation(value)) }

        case "response.text.done", "response.audio_transcript.done":
            let value = event["text"] as? String
                ?? event["transcript"] as? String ?? ""
            emit(.translationComplete(value))

        case "response.audio.delta":
            if let encoded = event["delta"] as? String,
               let audio = Data(base64Encoded: encoded) {
                emit(.audio(audio))
            }

        case "response.audio.done":
            emit(.audioComplete)

        case "input_audio_buffer.speech_started":
            BridgeLog.socket.notice("[\(self.diagnosticLabel, privacy: .public)] speech started stream=\(self.streamID, privacy: .public) item=\(identity.itemID ?? "?", privacy: .public) audio_ms=\(identity.audioMS ?? -1)")
            emit(.speechStarted)

        case "input_audio_buffer.speech_stopped":
            BridgeLog.socket.notice("[\(self.diagnosticLabel, privacy: .public)] speech stopped stream=\(self.streamID, privacy: .public) item=\(identity.itemID ?? "?", privacy: .public) audio_ms=\(identity.audioMS ?? -1)")
            emit(.speechStopped)

        case "session.finished":
            emit(.finished)
            resumeFinish()
            // Unsolicited, this is the service closing a session that went
            // quiet — the exact case where a pause in the conversation
            // otherwise ends the subtitles for good. Only a `finish()` we
            // asked for is the end of the stream; anything else reopens.
            if !isClosingNow {
                BridgeLog.socket.notice(
                    "service finished the session unprompted; reopening"
                )
                markDead(reason: "service closed an idle session")
            }

        case "error":
            let message = (event["error"] as? [String: Any])?["message"] as? String
                ?? text
            BridgeLog.socket.error("service error: \(message, privacy: .public)")
            handleServiceError(message)

        default:
            // An event the parser does not know is indistinguishable from a
            // dead socket at the UI, so name it rather than dropping it.
            BridgeLog.socket.notice("unhandled event: \(type, privacy: .public)")
        }
    }

    // MARK: - testing

    #if DEBUG
    func receiveFrameForTesting(_ frame: String) { handle(frame) }

    /// Drives the across-a-drop audio buffer without a socket.
    ///
    /// The reconnect itself needs a live service to exercise, but the part
    /// that decides whether a sentence spoken across the gap survives is
    /// plain state: what `sendAudio` does while the socket is down, and what
    /// `session.updated` replays afterwards. That part is worth pinning,
    /// because getting it wrong looks exactly like the bug reconnecting was
    /// added to fix — the call recovers, and the words spoken during the
    /// recovery are gone.
    func simulateDropForTesting() {
        lock.lock()
        task = nil
        session = nil
        isOpen = false
        isDead = true
        sawSessionUpdated = false
        lock.unlock()
    }

    /// The bytes currently held for replay.
    var bufferedBytesForTesting: Int {
        lock.lock(); defer { lock.unlock() }
        return reconnectBufferedBytes
    }

    /// The chunks currently held for replay, oldest first.
    var bufferedChunksForTesting: [Data] {
        lock.lock(); defer { lock.unlock() }
        return reconnectBuffer
    }

    /// Moves the held audio onto the pending queue the way a reopened
    /// session's `session.updated` does, and reports what is now queued.
    func drainBufferForTesting() -> [Data] {
        lock.lock()
        let carried = reconnectBuffer
        reconnectBuffer.removeAll()
        reconnectBufferedBytes = 0
        pendingAudio.insert(contentsOf: carried, at: 0)
        pendingAudioBytes += carried.reduce(0) { $0 + $1.count }
        let queued = pendingAudio
        lock.unlock()
        return queued
    }

    /// Retires the client the way `close()` does, without a socket to cancel.
    func retireForTesting() {
        lock.lock()
        isRetired = true
        lock.unlock()
    }

    /// The cap the replay buffer is trimmed to, so a test can state its
    /// expectation in terms of the same budget rather than a copied literal.
    static var reconnectBufferBytesForTesting: Int { reconnectBufferBytes }
    #endif
}
