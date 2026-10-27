import Foundation

/// Seeduplex 3.0 JSON WebSocket transport. It owns no audio devices and never
/// reconnects: a new paid session is always an explicit caller decision.
nonisolated final class DoubaoRealtimeClient: @unchecked Sendable {
    static let endpoint = URL(string: "wss://openspeech.bytedance.com/api/v3/duplex/realtime/dialogue")!
    static let defaultVoice = "zh_female_vv_jupiter_bigtts"

    struct Config: Sendable {
        var apiKey: String
        var instructions: String
        var voice: String = DoubaoRealtimeClient.defaultVoice
        /// Only set to resume an existing server conversation.
        var sessionID: String?
    }

    indirect enum JSONValue: Sendable, Equatable, Codable {
        case object([String: JSONValue]), array([JSONValue]), string(String)
        case number(Double), bool(Bool), null

        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() { self = .null }
            else if let v = try? value.decode(Bool.self) { self = .bool(v) }
            else if let v = try? value.decode(String.self) { self = .string(v) }
            else if let v = try? value.decode(Double.self) { self = .number(v) }
            else if let v = try? value.decode([String: JSONValue].self) { self = .object(v) }
            else { self = .array(try value.decode([JSONValue].self)) }
        }

        func encode(to encoder: any Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self {
            case .object(let v): try value.encode(v)
            case .array(let v): try value.encode(v)
            case .string(let v): try value.encode(v)
            case .number(let v): try value.encode(v)
            case .bool(let v): try value.encode(v)
            case .null: try value.encodeNil()
            }
        }

        subscript(_ key: String) -> JSONValue? {
            guard case .object(let object) = self else { return nil }
            return object[key]
        }
        var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    }

    enum ContextRole: String, Sendable { case user, assistant }
    struct ContextItem: Sendable {
        var role: ContextRole
        var text: String
        var id: String?
        init(role: ContextRole, text: String, id: String? = nil) {
            self.role = role; self.text = text; self.id = id
        }
    }

    struct Event: Sendable, Equatable {
        enum Kind: String, Sendable {
            case ready, sourceSpeechStarted, sourceTranscript, responseText
            case audio, audioComplete, responseDone, interrupted, failed, closed, other
        }
        var kind: Kind
        var eventID: String?
        var responseID: String?
        var itemID: String?
        var sessionID: String?
        var text: String?
        var audio: Data?
        var isFinal = false
        var payload: JSONValue = .null
    }

    enum ProtocolError: Error, LocalizedError {
        case invalidEvent(String)
        var errorDescription: String? {
            if case .invalidEvent(let message) = self { return message }
            return nil
        }
    }

    private let callbackLock = NSLock()
    private var eventCallback: (@Sendable (Event) -> Void)?
    private var diagnosticCallback: (@Sendable (Event) -> Void)?
    var onEvent: (@Sendable (Event) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return eventCallback }
        set { callbackLock.lock(); defer { callbackLock.unlock() }; eventCallback = newValue }
    }
    /// Independent receipt observer for acknowledgments and usage. It sees
    /// validated server events even when cancellation gates consumer output.
    var onDiagnosticEvent: (@Sendable (Event) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return diagnosticCallback }
        set { callbackLock.lock(); defer { callbackLock.unlock() }; diagnosticCallback = newValue }
    }
    private let queue = DispatchQueue(label: "app.livetranslate.doubao-realtime")
    private let urlSession: URLSession
    private var config: Config
    private enum State { case idle, connecting, ready, closing, closed, failed }
    private var state = State.idle
    private var socket: URLSessionWebSocketTask?
    private var serverSessionID: String?
    private var readyWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var closeWaiters: [CheckedContinuation<Bool, Never>] = []
    private var closeAcknowledged = false
    private var outgoing: [(value: JSONValue, audioBytes: Int)] = []
    private var sending = false
    private var pendingPCM = Data()
    private var audioTickScheduled = false
    private var audioDeadline: DispatchTime?
    private var audioScheduleGeneration = 0
    private var handshakeTimeout: TimeInterval = 15
    private var inputMuted = false
    private var commitPending = false
    private var muteAfterCommit = false
    private var activeResponseID: String?
    private var canceledResponses: Set<String> = []
    private var canceledOrder: [String] = []
    private var responseGate = false
    private var inputAfterCancel = false
    private var waitingForCancelAck = false
    private var contextPair: ContextItem?
    #if DEBUG
    private var testSender: (@Sendable (JSONValue) -> Void)?
    #endif

    init(config: Config) {
        self.config = config
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        urlSession = URLSession(configuration: configuration)
    }

    deinit {
        socket?.cancel(with: .goingAway, reason: nil)
        urlSession.invalidateAndCancel()
    }

    func connect() {
        queue.async { [self] in
            guard state == .idle else { return }
            guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !config.voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                fail("Realtime API Key and voice are required"); return
            }
            state = .connecting
            queue.asyncAfter(deadline: .now() + handshakeTimeout) { [weak self] in
                guard let self, self.state == .connecting else { return }
                self.fail("Timed out waiting for realtime session.created")
            }
            #if DEBUG
            if testSender != nil { enqueue(Self.createEvent(config: config)); return }
            #endif
            var request = URLRequest(url: Self.endpoint)
            request.setValue(config.apiKey, forHTTPHeaderField: "X-Api-Key")
            let task = urlSession.webSocketTask(with: request)
            task.maximumMessageSize = 2 * 1024 * 1024
            socket = task
            task.resume()
            receive()
            enqueue(Self.createEvent(config: config))
        }
    }

    func waitUntilReady(timeout: TimeInterval = 15) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if state == .ready { continuation.resume(returning: true); return }
                guard state == .idle || state == .connecting,
                      timeout.isFinite, timeout > 0 else { continuation.resume(returning: false); return }
                let id = UUID()
                readyWaiters[id] = continuation
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self, self.readyWaiters[id] != nil else { return }
                    self.fail("Timed out waiting for realtime session.created")
                }
            }
        }
    }

    /// Input is 16 kHz mono Int16 LE. Arbitrary capture blocks are packetized
    /// into 640-byte/20 ms frames; commit flushes the final shorter packet.
    func appendAudio(_ pcm: Data) {
        queue.async { [self] in
            guard state == .ready || state == .connecting, !pcm.isEmpty else { return }
            guard pcm.count.isMultiple(of: 2) else { fail("Realtime input contains an incomplete Int16 sample"); return }
            guard !inputMuted, !muteAfterCommit, !commitPending else {
                fail("Unmute realtime input and finish its commit before appending audio"); return
            }
            let queuedBytes = outgoing.reduce(0) { $0 + $1.audioBytes }
            guard pendingPCM.count + queuedBytes + pcm.count <= 64_000 else {
                fail("Realtime input exceeded its two-second audio backlog"); return
            }
            pendingPCM.append(pcm)
            inputAfterCancel = true
            scheduleAudioTick()
        }
    }

    func commitAudio() {
        queue.async { [self] in
            guard state == .ready else { return }
            commitPending = true
            inputAfterCancel = true
            scheduleAudioTick()
        }
    }

    /// Muting concerns input/keepalive only. It never discards a model reply.
    /// Pair with cancelResponse when taking the call over.
    func setMuted(_ muted: Bool) {
        queue.async { [self] in
            guard state == .ready || state == .connecting else { return }
            if muted, commitPending {
                muteAfterCommit = true
                return
            }
            muteAfterCommit = false
            guard inputMuted != muted else { return }
            if muted {
                // A microphone takeover must not replay stale capture blocks
                // when it is unmuted. A committed query is drained above.
                pendingPCM.removeAll()
                outgoing.removeAll { $0.audioBytes > 0 }
                invalidateAudioSchedule()
            }
            inputMuted = muted
            enqueue(Self.control(muted ? "input_audio_mute.commit" : "input_audio_unmute.commit"))
            if !muted { scheduleAudioTick() }
        }
    }

    func cancelResponse() {
        queue.async { [self] in
            guard state == .ready else { return }
            responseGate = true
            inputAfterCancel = false
            if let id = activeResponseID {
                blockResponse(id)
                waitingForCancelAck = true
                enqueue(Self.control("response.cancel"))
            }
            activeResponseID = nil
        }
    }

    func updateInstructions(_ instructions: String) {
        queue.async { [self] in
            guard state == .ready || state == .connecting else { return }
            config.instructions = instructions
            var session = Self.session(config)
            if let serverSessionID { session["id"] = .string(serverSessionID) }
            enqueue(Self.control("session.update", fields: ["session": .object(session)]))
        }
    }

    /// Context creation stores complete user/assistant QA, not a text query.
    func injectContext(_ items: [ContextItem]) {
        queue.async { [self] in
            guard state == .ready else { return }
            guard !items.isEmpty, items.count <= 40, items.count.isMultiple(of: 2),
                  items.enumerated().allSatisfy({ $0.element.role == ($0.offset.isMultiple(of: 2) ? .user : .assistant) }) else {
                fail("Realtime context must contain 1–20 complete user/assistant pairs"); return
            }
            enqueue(Self.contextEvent(items))
        }
    }

    /// Convenience for callers assembling one complete QA pair in order.
    func appendConversation(role: ContextRole, text: String, id: String? = nil) {
        queue.async { [self] in
            guard state == .ready else { return }
            let item = ContextItem(role: role, text: text, id: id)
            if role == .user { contextPair = item; return }
            guard let user = contextPair else { fail("Realtime assistant context requires a preceding user item"); return }
            contextPair = nil
            enqueue(Self.contextEvent([user, item]))
        }
    }

    /// Direct greeting synthesis, NOT a text query asking the model to reason.
    func speak(_ text: String) {
        queue.async { [self] in
            guard state == .ready, !text.isEmpty else { return }
            inputAfterCancel = true
            enqueue(Self.control("speech_text_buffer.commit", fields: ["text": .string(text)]))
        }
    }

    /// Returns true only after an actual server session.closed acknowledgment.
    func close(timeout: TimeInterval = 5) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if state == .closed || state == .failed {
                    continuation.resume(returning: closeAcknowledged); return
                }
                guard state != .idle else {
                    retire(acknowledged: false); continuation.resume(returning: false); return
                }
                closeWaiters.append(continuation)
                guard state != .closing else { return }
                state = .closing
                pendingPCM.removeAll(); commitPending = false; muteAfterCommit = false
                outgoing.removeAll { $0.audioBytes > 0 }
                responseGate = true
                enqueue(Self.control("session.close"))
                let limit = timeout.isFinite && timeout > 0 ? timeout : 5
                queue.asyncAfter(deadline: .now() + limit) { [weak self] in
                    guard let self, self.state == .closing else { return }
                    self.fail("Timed out waiting for realtime session.closed")
                }
            }
        }
    }

    func abort() { queue.async { [self] in retire(acknowledged: false) } }

    // MARK: wire contract

    private static func session(_ config: Config) -> [String: JSONValue] {
        var session: [String: JSONValue] = [
            "model": .string("1.2.6.1"), "instructions": .string(config.instructions),
            "audio": .object([
                "input": .object(["format": .object(["type": .string("pcm"), "rate": .number(16_000)])]),
                "output": .object(["format": .object(["type": .string("pcm_s16le"), "rate": .number(24_000)]),
                                   "voice": .string(config.voice)]),
            ]),
        ]
        if let id = config.sessionID, !id.isEmpty { session["id"] = .string(id) }
        return session
    }

    static func createEvent(config: Config) -> JSONValue {
        control("session.create", fields: ["session": .object(session(config))])
    }

    private static func control(_ type: String, fields: [String: JSONValue] = [:]) -> JSONValue {
        var event = fields
        event["type"] = .string(type)
        event["event_id"] = .string(UUID().uuidString)
        return .object(event)
    }

    static func contextEvent(_ items: [ContextItem]) -> JSONValue {
        control("conversation.item.create", fields: ["items": .array(items.map { item in
            var value: [String: JSONValue] = [
                "type": .string("message"), "role": .string(item.role.rawValue),
                "content": .array([.object(["type": .string("input_text"), "text": .string(item.text)])]),
            ]
            if let id = item.id { value["id"] = .string(id) }
            return .object(value)
        })])
    }

    static func decodeEvent(_ data: Data) throws -> Event {
        let payload = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object = payload, let type = payload["type"]?.stringValue else {
            throw ProtocolError.invalidEvent("Realtime event has no string type")
        }
        var event = Event(kind: .other, eventID: payload["event_id"]?.stringValue,
                          responseID: payload["response_id"]?.stringValue,
                          itemID: payload["item_id"]?.stringValue,
                          sessionID: payload["session"]?["id"]?.stringValue, payload: payload)
        switch type {
        case "session.created": event.kind = .ready
        case "session.closed": event.kind = .closed; event.isFinal = true
        case "conversation.item.input_audio_transcription.started": event.kind = .sourceSpeechStarted
        case "conversation.item.input_audio_transcription.delta":
            event.kind = .sourceTranscript; event.text = payload["delta"]?.stringValue
        case "conversation.item.input_audio_transcription.completed":
            event.kind = .sourceTranscript; event.isFinal = true
            event.text = payload["transcript"]?.stringValue ?? payload["text"]?.stringValue
        case "response.output_text.delta": event.kind = .responseText; event.text = payload["delta"]?.stringValue
        case "response.output_text.done":
            event.kind = .responseText; event.text = payload["text"]?.stringValue; event.isFinal = true
        case "response.output_audio.delta":
            guard let base64 = payload["delta"]?.stringValue, let audio = Data(base64Encoded: base64),
                  audio.count.isMultiple(of: 2) else {
                throw ProtocolError.invalidEvent("Realtime returned invalid Int16 audio")
            }
            event.kind = .audio; event.audio = audio
        case "response.output_audio.done": event.kind = .audioComplete; event.isFinal = true
        case "response.done": event.kind = .responseDone; event.isFinal = true
        case "response.canceled": event.kind = .interrupted; event.isFinal = true
        case "error", "conversation.item.input_audio_transcription.failed":
            event.kind = .failed
            event.text = payload["error"]?["message"]?.stringValue ?? payload["message"]?.stringValue
                ?? "Realtime service returned \(type)"
        default: break
        }
        return event
    }

    // MARK: serialized transport/state

    private func receive() {
        guard let socket, state != .closed, state != .failed else { return }
        socket.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.state != .closed, self.state != .failed else { return }
                switch result {
                case .failure(let error): self.fail(self.transportMessage(error))
                case .success(let frame):
                    switch frame {
                    case .string(let text): self.handle(Data(text.utf8))
                    case .data: self.fail("Realtime 3.0 expected a JSON text WebSocket frame")
                    @unknown default: self.fail("Realtime returned an unsupported WebSocket frame")
                    }
                    self.receive()
                }
            }
        }
    }

    private func handle(_ data: Data) {
        guard state != .closed, state != .failed else { return }
        do {
            var event = try Self.decodeEvent(data)
            event.sessionID = event.sessionID ?? serverSessionID
            // The actual 3.0 service omits response_id on audio deltas and
            // response.done. The surrounding started/text/done events name it.
            if event.payload["type"]?.stringValue?.hasPrefix("response.") == true {
                event.responseID = event.responseID ?? activeResponseID
            }
            if event.kind == .failed { fail(event.text ?? "Realtime service failed", event: event); return }
            onDiagnosticEvent?(event)
            if event.kind == .closed { onEvent?(event); retire(acknowledged: true); return }
            if event.kind == .ready {
                serverSessionID = event.sessionID
                if state == .connecting { state = .ready; resolveReady(true); scheduleAudioTick() }
            }
            if state == .closing { return }
            if event.kind == .interrupted { waitingForCancelAck = false; activeResponseID = nil }
            let responseEvent = [.responseText, .audio, .audioComplete, .responseDone].contains(event.kind)
                || event.payload["type"]?.stringValue == "response.output_audio.started"
            if responseEvent {
                if let id = event.responseID, canceledResponses.contains(id) { return }
                if responseGate {
                    guard !waitingForCancelAck, inputAfterCancel, let id = event.responseID else {
                        if let id = event.responseID { blockResponse(id) }
                        return
                    }
                    guard !canceledResponses.contains(id) else { return }
                    responseGate = false
                }
                if let id = event.responseID { activeResponseID = id }
                if event.kind == .responseDone { activeResponseID = nil }
            }
            onEvent?(event)
        } catch { fail("Invalid realtime event: \(error.localizedDescription)") }
    }

    private func scheduleAudioTick() {
        guard state == .ready, !audioTickScheduled, !inputMuted,
              pendingPCM.count >= 640 || commitPending else { return }
        audioTickScheduled = true
        let generation = audioScheduleGeneration
        let deadline = audioDeadline ?? .now()
        audioDeadline = deadline
        queue.asyncAfter(deadline: deadline) { [weak self] in
            guard let self, generation == self.audioScheduleGeneration else { return }
            self.audioTick()
        }
    }

    private func audioTick() {
        audioTickScheduled = false
        guard state == .ready, !inputMuted else { return }
        if pendingPCM.count >= 640 || (commitPending && !pendingPCM.isEmpty) {
            let count = min(640, pendingPCM.count)
            let pcm = Data(pendingPCM.prefix(count))
            pendingPCM.removeFirst(count)
            enqueue(Self.control("input_audio_buffer.append", fields: ["audio": .string(pcm.base64EncodedString())]), audioBytes: count)
            // Anchor to the preceding deadline, not completion of encoding or
            // enqueueing. Ordinary work/jitter therefore does not accumulate
            // into an ever-growing capture backlog. A missed whole interval
            // starts a new cadence instead of bursting catch-up packets.
            let now = DispatchTime.now()
            let planned = (audioDeadline ?? now) + .milliseconds(20)
            audioDeadline = planned > now ? planned : now + .milliseconds(20)
            audioTickScheduled = true
            let generation = audioScheduleGeneration
            queue.asyncAfter(deadline: audioDeadline!) { [weak self] in
                guard let self, generation == self.audioScheduleGeneration else { return }
                self.audioTick()
            }
            return
        }
        if commitPending {
            commitPending = false
            enqueue(Self.control("input_audio_buffer.commit"))
        }
        if muteAfterCommit, pendingPCM.isEmpty {
            muteAfterCommit = false; inputMuted = true
            enqueue(Self.control("input_audio_mute.commit"))
        }
        audioDeadline = nil
    }

    private func invalidateAudioSchedule() {
        audioScheduleGeneration &+= 1
        audioTickScheduled = false
        audioDeadline = nil
    }

    private func enqueue(_ value: JSONValue, audioBytes: Int = 0) {
        guard state != .closed, state != .failed else { return }
        #if DEBUG
        if let testSender { testSender(value); return }
        #endif
        guard outgoing.count < 256 else { fail("Realtime outbound queue exceeded its limit"); return }
        outgoing.append((value, audioBytes))
        pump()
    }

    private func pump() {
        guard !sending, let socket, !outgoing.isEmpty else { return }
        let message = outgoing.removeFirst()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(message.value)
            guard let text = String(data: data, encoding: .utf8) else { throw ProtocolError.invalidEvent("Cannot encode realtime JSON") }
            sending = true
            socket.send(.string(text)) { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    self.sending = false
                    guard self.state != .closed, self.state != .failed else { return }
                    if let error { self.fail(self.transportMessage(error)); return }
                    self.pump()
                }
            }
        } catch { fail("Cannot encode realtime event: \(error.localizedDescription)") }
    }

    private func blockResponse(_ id: String) {
        if canceledResponses.insert(id).inserted { canceledOrder.append(id) }
        if canceledOrder.count > 256 { canceledResponses.remove(canceledOrder.removeFirst()) }
    }

    private func transportMessage(_ error: any Error) -> String {
        var message = "Realtime WebSocket failed: \(error.localizedDescription)"
        if let response = socket?.response as? HTTPURLResponse {
            message += " (HTTP \(response.statusCode))"
            if let logID = response.value(forHTTPHeaderField: "X-Tt-Logid") { message += " logid=\(logID)" }
        }
        return message
    }

    private func resolveReady(_ ready: Bool) {
        let waiters = readyWaiters.values
        readyWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: ready) }
    }

    private func fail(_ message: String, event: Event? = nil) {
        guard state != .closed, state != .failed else { return }
        let safe = config.apiKey.isEmpty ? message : message.replacingOccurrences(of: config.apiKey, with: "[redacted]")
        var failure = event ?? Event(kind: .failed)
        failure.text = safe
        // Raw upstream error payloads can echo request data; retain only the
        // explicitly redacted diagnostic rather than any credential-bearing JSON.
        failure.payload = .object(["type": .string("error"), "message": .string(safe)])
        state = .failed
        onDiagnosticEvent?(failure)
        onEvent?(failure)
        retire(acknowledged: false, failed: true)
    }

    private func retire(acknowledged: Bool, failed: Bool = false) {
        closeAcknowledged = closeAcknowledged || acknowledged
        state = failed ? .failed : .closed
        invalidateAudioSchedule()
        responseGate = true
        pendingPCM.removeAll(); outgoing.removeAll(); contextPair = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        urlSession.invalidateAndCancel()
        resolveReady(false)
        let waiters = closeWaiters; closeWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: closeAcknowledged) }
    }

    #if DEBUG
    convenience init(config: Config, handshakeTimeoutForTesting: TimeInterval = 15,
                     sendForTesting: @escaping @Sendable (JSONValue) -> Void) {
        self.init(config: config)
        handshakeTimeout = handshakeTimeoutForTesting
        testSender = sendForTesting
    }
    func applyForTesting(_ json: String) { queue.sync { handle(Data(json.utf8)) } }
    func flushForTesting() { queue.sync {} }
    #endif
}
