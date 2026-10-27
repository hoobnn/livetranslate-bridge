import os
import Foundation
import Observation

nonisolated protocol CallAgentRealtimeSession: AnyObject, Sendable {
    var onEvent: (@Sendable (DoubaoRealtimeClient.Event) -> Void)? { get set }
    func connect()
    func appendAudio(_ pcm: Data)
    func cancelResponse()
    func setMuted(_ muted: Bool)
    func updateInstructions(_ instructions: String)
    func injectContext(_ items: [DoubaoRealtimeClient.ContextItem])
    func speak(_ text: String)
    func abort()
}

extension DoubaoRealtimeClient: CallAgentRealtimeSession {}

/// Holds up the user's side of a call on their behalf, from reference
/// material they supply, until they take over.
///
/// Realtime mode consumes the far end's PCM and returns conversational speech
/// and spoken-language subtitles. Its voice is independent of the translation
/// voice used during human takeover. The optional legacy backend answers
/// finished transcripts through a chat model and standalone TTS; that path
/// shares its selected stock or cloned voice with the user's translation.
///
/// Taking over is immediate: the moment the user starts speaking — or
/// presses Take Over — the agent stops talking, drops any reply it was
/// preparing, and stays quiet until handed the call back. What the user said
/// meanwhile is kept in its history, so it resumes knowing what was agreed.
@Observable
final class CallAgent {
    enum Backend: String, CaseIterable, Sendable {
        case doubaoRealtime
        case chatAndTTS
    }
    enum Phase: Equatable {
        /// No session, or the agent was not asked for.
        case off
        /// Waiting for the far end to finish speaking.
        case listening
        /// A reply is being written.
        case thinking
        /// A reply is being spoken.
        case speaking
        /// The user is talking; the agent stays quiet until handed back.
        case handedOver
        case failed(String)

        var isActive: Bool {
            switch self {
            case .listening, .thinking, .speaking: true
            default: false
            }
        }
    }

    struct Turn: Equatable {
        /// What the far end hears, in their language.
        var say: String
        /// The same, in the user's language, for the board.
        var gloss: String
        /// The model judged the call finished.
        var hangsUp: Bool
    }

    struct Config {
        var materials: String
        var goal: String
        var theirLanguage: String
        var myLanguage: String
        var chat: CredentialStore.AgentCredentials
        var speech: CredentialStore.DoubaoCredentials
        /// The voice replies are spoken in.
        var speakerID: String
        var backend: Backend = .chatAndTTS
        var realtimeVoice: String = DoubaoRealtimeClient.defaultVoice
    }

    /// Live defaults keep production requests unchanged; tests can control
    /// completion and cancellation without networking or audio playback.
    struct Services {
        var complete: @Sendable ([ChatCompletionClient.Message], CredentialStore.AgentCredentials) async throws -> String = {
            try await ChatCompletionClient.complete($0, credentials: $1)
        }
        var synthesize: @Sendable (
            String, String, String?, CredentialStore.DoubaoCredentials,
            @escaping @Sendable (Data) -> Void
        ) async throws -> Void = { text, speaker, language, credentials, onAudio in
            try await DoubaoVoiceServices.synthesize(
                text: text, speaker: speaker, language: language,
                credentials: credentials, onAudio: onAudio
            )
        }
        var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        var makeRealtime: @Sendable (DoubaoRealtimeClient.Config) -> any CallAgentRealtimeSession = {
            DoubaoRealtimeClient(config: $0)
        }
    }

    @ObservationIgnored private let services: Services

    init(services: Services? = nil) {
        self.services = services ?? Services()
    }

    private(set) var phase: Phase = .off
    private(set) var isRealtimeConnecting = false

    /// How long the far end must stay quiet after a sentence before the
    /// agent answers. Long enough not to talk over a pause mid-thought, short
    /// enough not to leave dead air on the line.
    @ObservationIgnored var replyDelay: Duration = .milliseconds(900)

    @ObservationIgnored var onTurn: ((Turn) -> Void)?
    @ObservationIgnored var onTurnUpdated: ((Turn, Turn) -> Void)?
    @ObservationIgnored var onAudio: (@Sendable (Data) -> Void)?
    /// The current reply's audio must stop now.
    @ObservationIgnored var onInterrupt: (() -> Void)?
    /// A reply finished streaming.
    @ObservationIgnored var onSpeechEnd: (() -> Void)?
    /// A turn already shown was never heard: its speech failed or was cut
    /// off before the first sound.
    @ObservationIgnored var onTurnWithdrawn: ((Turn) -> Void)?

    @ObservationIgnored private var config: Config?
    @ObservationIgnored private var history: [ChatCompletionClient.Message] = []
    @ObservationIgnored private var unanswered: [String] = []
    /// The utterance our last `assistant` message came from, and where it
    /// sits, so a sentence re-sent as it grows replaces itself.
    @ObservationIgnored private var lastLocal: (utterance: String, index: Int)?
    @ObservationIgnored private var replyTask: Task<Void, Never>?
    private struct AudioState {
        var active = true
        var heard = false
    }
    @ObservationIgnored private var pendingTurn: (
        turn: Turn, index: Int, audio: OSAllocatedUnfairLock<AudioState>
    )?
    /// Whether the user held the call when it last ended, for `resuming`.
    @ObservationIgnored private var endedHandedOver = false
    /// Bumped by everything that invalidates a reply in flight.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var realtime: (any CallAgentRealtimeSession)?
    @ObservationIgnored private var realtimeEpoch = 0
    @ObservationIgnored private let realtimeDelivery = OSAllocatedUnfairLock(initialState: 0)
    @ObservationIgnored private let realtimeInput = RealtimeInput()
    @ObservationIgnored private var realtimeText = ""
    @ObservationIgnored private var realtimePublished: Turn?
    @ObservationIgnored private var realtimeHeard = false
    @ObservationIgnored private var realtimeCommitted = false
    @ObservationIgnored private var realtimeResponseID: String?
    @ObservationIgnored private var realtimeCanceledIDs: Set<String> = []
    @ObservationIgnored private var pendingRealtimeContext: [DoubaoRealtimeClient.ContextItem] = []
    @ObservationIgnored private var realtimeAcceptsOutput = true
    @ObservationIgnored private var manualHistoryStart = 0
    @ObservationIgnored private var manualRecords: [ChatCompletionClient.Message] = []
    @ObservationIgnored private var manualBaseRecords: [ChatCompletionClient.Message] = []
    @ObservationIgnored private var manualCaptureActive = false

    private nonisolated final class RealtimeInput: @unchecked Sendable {
        let session = OSAllocatedUnfairLock<(any CallAgentRealtimeSession)?>(initialState: nil)
        func install(_ value: (any CallAgentRealtimeSession)?) { session.withLock { $0 = value } }
        func append(_ pcm: Data) { session.withLock { $0?.appendAudio(pcm) } }
    }

    nonisolated func appendRemoteAudio(_ pcm: Data) { realtimeInput.append(pcm) }

    func realtimeAudioSink() -> (@Sendable (Data) -> Void)? {
        guard config?.backend == .doubaoRealtime else { return nil }
        let input = realtimeInput
        return { pcm in input.append(pcm) }
    }

    /// Starts a call. Replies only after the far end speaks first, which is
    /// how a call one answers goes; use `speakFirst` to open it instead.
    /// `resuming` keeps what was said so far, for a session rebuilt mid-call
    /// (an audio device came back, say) that is still the same conversation.
    func begin(_ config: Config, resuming: Bool = false) {
        let shouldInterrupt = phase.isActive || isFailed
        let wasHandedOver = phase == .handedOver || (phase == .off && endedHandedOver)
        cancelReply()
        closeRealtime()
        if shouldInterrupt { onInterrupt?() }
        self.config = config
        if !resuming {
            history = []
            unanswered = []
            manualRecords = []
            manualBaseRecords = []
            manualCaptureActive = false
        }
        lastLocal = nil
        // A call we had taken over stays ours across a rebuild.
        phase = resuming && wasHandedOver ? .handedOver : .listening
        if config.backend == .doubaoRealtime {
            startRealtime(config, resuming: resuming)
            return
        }
        // A reply the rebuild cut off is still owed.
        if resuming, phase == .listening,
           !unanswered.isEmpty || history.last?.role == .user {
            scheduleReply(after: replyDelay)
        }
    }

    func end() {
        if manualCaptureActive { flushUnanswered(); captureManualRecords() }
        // Ending twice (stop, then the restart's own reset) must not
        // forget how the first one found the call.
        if phase != .off { endedHandedOver = phase == .handedOver }
        let shouldInterrupt = phase.isActive || isFailed
        cancelReply()
        closeRealtime()
        if shouldInterrupt { onInterrupt?() }
        config = nil
        phase = .off
    }

    /// Saves edits to the goal or material. Legacy replies use them next;
    /// realtime applies them to a new session on the next explicit handback.
    func updateBrief(materials: String, goal: String) {
        config?.materials = materials
        config?.goal = goal
        // Realtime edits are applied in the next explicit handback's initial
        // instructions. Updating the server session was acknowledged without
        // changing model behavior in verified calls. Never open a paid new
        // session for each keystroke in the editor.
    }

    /// Opens with a model-written greeting in legacy mode, or a literal short
    /// greeting in realtime mode, whose speech API does not infer text answers.
    func speakFirst() {
        guard phase == .listening, !isRealtimeConnecting else { return }
        if config?.backend == .doubaoRealtime {
            realtimeAcceptsOutput = true
            // This API speaks supplied text; it does not turn a text prompt
            // into an inferred answer. Open with a literal greeting only.
            realtime?.speak(config?.theirLanguage == "en" ? "Hello." : "您好。")
            return
        }
        scheduleReply(after: .zero)
    }

    // MARK: - what the call hears

    /// The far end started a sentence. A reply still being written answers
    /// what they said before it, so it is thrown away and rewritten once
    /// they finish; one being spoken stops, rather than talk over them.
    func noteRemoteSpeechStarted() {
        if config?.backend == .doubaoRealtime { return }
        guard phase.isActive else { return }
        cancelReply()
        // Synthesis can finish before the player's queued audio does.
        // Every new remote utterance therefore interrupts that queue too.
        onInterrupt?()
        phase = .listening
    }

    func noteRemote(_ sentence: String) {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard config != nil, !text.isEmpty else { return }
        if config?.backend == .doubaoRealtime {
            // The realtime model consumes PCM itself. AST text is only used
            // to remember the human-held part while realtime input is muted.
            if phase == .handedOver { unanswered.append(text) }
            return
        }
        unanswered.append(text)
        guard phase == .listening || phase == .thinking else { return }
        scheduleReply(after: replyDelay)
    }

    /// The user started speaking: they have the floor.
    func noteLocalSpeech() {
        guard phase.isActive else { return }
        takeOver()
    }

    /// Something the user said themselves, in the far end's language when
    /// the translation is known. `utterance` names the sentence it belongs
    /// to: a sentence translated in parts arrives again whole as each part
    /// lands, and replaces what it said before rather than adding to it.
    func noteLocal(_ sentence: String, utterance: String? = nil) {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard config != nil, !text.isEmpty else { return }
        if let utterance, let last = lastLocal, last.utterance == utterance,
           history.indices.contains(last.index), history[last.index].role == .assistant {
            history[last.index].content = text
            if manualCaptureActive { captureManualRecords() }
            return
        }
        flushUnanswered()
        history.append(.init(role: .assistant, content: text))
        lastLocal = utterance.map { ($0, history.count - 1) }
        if manualCaptureActive { captureManualRecords() }
    }

    func takeOver() {
        guard config != nil else { return }
        if config?.backend == .doubaoRealtime {
            realtimeInput.install(nil)
            invalidateRealtimeOutput()
            realtime?.cancelResponse()
            realtime?.setMuted(true)
            finishRealtimeTurn(interrupted: true)
            manualHistoryStart = history.last?.role == .user ? max(0, history.count - 1) : history.count
            manualBaseRecords = manualRecords
            manualCaptureActive = true
        }
        cancelReply()
        onInterrupt?()
        phase = .handedOver
    }

    func handBack() {
        guard config != nil, phase == .handedOver || isFailed else { return }
        if let config, config.backend == .doubaoRealtime {
            if manualCaptureActive { flushUnanswered(); captureManualRecords() }
            manualCaptureActive = false
            // The provider acknowledges session.update but the live model
            // retained its original brief in verified calls. A human handback
            // explicitly starts a new model session with the updated initial
            // instructions, then restores bounded QA after ready.
            phase = .listening
            begin(config, resuming: true)
            return
        }
        // A reply that failed had already taken the far end's words into
        // the history; they are still owed an answer.
        // An opening that failed is owed too: nothing was said yet at all.
        let owed = isFailed && (history.last?.role == .user || history.isEmpty)
        phase = .listening
        if !unanswered.isEmpty || owed { scheduleReply(after: replyDelay) }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func closeRealtime() {
        realtimeEpoch &+= 1
        invalidateRealtimeOutput()
        realtimeInput.install(nil)
        realtime?.onEvent = nil
        realtime?.abort()
        realtime = nil
        isRealtimeConnecting = false
        pendingRealtimeContext = []
        finishRealtimeTurn(interrupted: true)
    }

    private func invalidateRealtimeOutput() {
        realtimeDelivery.withLock { $0 &+= 1 }
        realtimeAcceptsOutput = false
        if let id = realtimeResponseID { realtimeCanceledIDs.insert(id) }
    }

    private func startRealtime(_ config: Config, resuming: Bool) {
        guard config.speech.appID.isEmpty, config.speech.isComplete else {
            phase = .failed("Doubao realtime requires an API Key without App ID")
            return
        }
        realtimeText = ""
        realtimePublished = nil
        realtimeHeard = false
        realtimeCommitted = false
        realtimeResponseID = nil
        realtimeCanceledIDs = []
        pendingRealtimeContext = resuming ? Self.contextPairs(history) : []
        realtimeAcceptsOutput = phase != .handedOver
        let session = services.makeRealtime(.init(
            apiKey: config.speech.accessToken, instructions: realtimeInstructions(config),
            voice: config.realtimeVoice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? DoubaoRealtimeClient.defaultVoice
                : config.realtimeVoice.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        realtime = session
        isRealtimeConnecting = true
        realtimeInput.install(nil)
        let epoch = realtimeEpoch
        let delivery = realtimeDelivery
        session.onEvent = { [weak self] event in
            let received = delivery.withLock { $0 }
            Task { @MainActor [weak self] in
                guard let self, self.realtimeEpoch == epoch,
                      received == delivery.withLock({ $0 }),
                      self.config?.backend == .doubaoRealtime else { return }
                self.handleRealtime(event)
            }
        }
        session.connect()
        if phase == .handedOver { session.setMuted(true) }
    }

    private func handleRealtime(_ event: DoubaoRealtimeClient.Event) {
        switch event.kind {
        case .ready:
            isRealtimeConnecting = false
            if !pendingRealtimeContext.isEmpty {
                realtime?.injectContext(pendingRealtimeContext)
                pendingRealtimeContext = []
            }
            if phase != .handedOver { realtimeInput.install(realtime) }
        case .sourceSpeechStarted:
            guard phase != .handedOver else { return }
            finishRealtimeTurn(interrupted: true)
            if let id = realtimeResponseID { realtimeCanceledIDs.insert(id) }
            realtimeResponseID = nil
            realtimeText = ""
            realtimeHeard = false
            realtimeCommitted = false
            realtimeAcceptsOutput = true
            onInterrupt?()
            phase = .listening
        case .sourceTranscript:
            guard phase != .handedOver, event.isFinal,
                  let text = event.text, !text.isEmpty else { return }
            history.append(.init(role: .user, content: text))
            phase = .thinking
        case .responseText, .audio, .audioComplete, .responseDone:
            guard phase != .handedOver, realtimeAcceptsOutput,
                  event.responseID.map({ !realtimeCanceledIDs.contains($0) }) ?? true else { return }
            if let id = event.responseID, realtimeResponseID != id {
                if realtimeResponseID != nil { finishRealtimeTurn(interrupted: true) }
                realtimeResponseID = id
                realtimeText = ""
                realtimePublished = nil
                realtimeHeard = false
                realtimeCommitted = false
            }
            switch event.kind {
            case .responseText:
                if let text = event.text {
                    realtimeText = event.isFinal ? text : realtimeText + text
                    guard !realtimeText.isEmpty else { break }
                    let turn = Turn(say: realtimeText, gloss: "", hangsUp: false)
                    if let previous = realtimePublished { onTurnUpdated?(previous, turn) }
                    else if !turn.say.isEmpty { onTurn?(turn) }
                    realtimePublished = turn
                    phase = .speaking
                }
            case .audio:
                if let audio = event.audio, !audio.isEmpty {
                    realtimeHeard = true
                    phase = .speaking
                    onAudio?(audio)
                }
            case .audioComplete:
                onSpeechEnd?()
            case .responseDone:
                finishRealtimeTurn(interrupted: false)
                phase = .listening
            default: break
            }
        case .interrupted:
            guard phase != .handedOver else { return }
            finishRealtimeTurn(interrupted: true)
            onInterrupt?()
            phase = .listening
        case .failed:
            finishRealtimeTurn(interrupted: true)
            invalidateRealtimeOutput()
            realtimeInput.install(nil)
            isRealtimeConnecting = false
            onInterrupt?()
            phase = .failed(event.text ?? "Doubao realtime session failed")
        case .closed:
            finishRealtimeTurn(interrupted: true)
            invalidateRealtimeOutput()
            realtimeInput.install(nil)
            isRealtimeConnecting = false
            onInterrupt?()
            phase = .failed("Doubao realtime session closed")
        case .other:
            break
        }
    }

    private func finishRealtimeTurn(interrupted: Bool) {
        if let turn = realtimePublished, !realtimeCommitted {
            if realtimeHeard, !turn.say.isEmpty {
                history.append(.init(role: .assistant, content: turn.say))
                realtimeCommitted = true
            } else {
                onTurnWithdrawn?(turn)
            }
        }
        if interrupted { realtimePublished = nil }
    }

    /// The protocol only accepts complete QA pairs. A trailing unanswered
    /// question is kept locally until the caller speaks again after handback.
    static func contextPairs(_ messages: [ChatCompletionClient.Message]) -> [DoubaoRealtimeClient.ContextItem] {
        var pairs: [DoubaoRealtimeClient.ContextItem] = []
        var question = ""
        var answer = ""
        func flush() {
            guard !question.isEmpty, !answer.isEmpty else { return }
            pairs += [.init(role: .user, text: question), .init(role: .assistant, text: answer)]
        }
        for message in messages {
            switch message.role {
            case .user:
                if !answer.isEmpty { flush(); question = ""; answer = "" }
                question = Self.combineContext(question, message.content)
            case .assistant:
                if !question.isEmpty { answer = Self.combineContext(answer, message.content) }
            case .system: break
            }
        }
        flush()
        return Self.boundedContext(pairs)
    }

    private static func boundedContext(_ items: [DoubaoRealtimeClient.ContextItem]) -> [DoubaoRealtimeClient.ContextItem] {
        // The service accepts at most twenty complete QA pairs. The byte
        // budget also bounds duplicated manual context in the instructions.
        let recent = Array(items.suffix(40))
        var pairs: [[DoubaoRealtimeClient.ContextItem]] = []
        var remaining = 16_000
        for index in stride(from: recent.count - 2, through: 0, by: -2) {
            guard index >= 0 else { break }
            var pair = Array(recent[index...index + 1])
            for offset in pair.indices {
                // Truncate at character boundaries, never inside UTF-8.
                pair[offset].text = Self.boundedText(pair[offset].text, bytes: 4_000)
            }
            let bytes = pair.reduce(0) { $0 + $1.text.utf8.count }
            guard bytes <= remaining else { break }
            remaining -= bytes
            pairs.append(pair)
        }
        return pairs.reversed().flatMap { $0 }
    }

    private static func combineContext(_ first: String, _ second: String) -> String {
        first.isEmpty ? second : first + "\n" + second
    }

    private static func boundedText(_ text: String, bytes limit: Int) -> String {
        var output = ""
        var bytes = 0
        for character in text {
            let count = character.utf8.count
            guard bytes + count <= limit else { break }
            output.append(character)
            bytes += count
        }
        return output
    }

    private func captureManualRecords() {
        let latest = manualBaseRecords + history.dropFirst(manualHistoryStart)
        var remaining = 16_000
        var bounded: [ChatCompletionClient.Message] = []
        for var message in latest.suffix(40).reversed() {
            message.content = Self.boundedText(message.content, bytes: min(4_000, remaining))
            if message.content.isEmpty { continue }
            remaining -= message.content.utf8.count
            bounded.append(message)
        }
        manualRecords = bounded.reversed()
    }

    private func realtimeInstructions(_ config: Config) -> String {
        let manual = manualRecords.map { "\($0.role == .user ? "对方" : "用户本人")：\($0.content)" }
            .joined(separator: "\n")
        return """
        你正在替用户本人打一通电话。以用户本人的第一人称自然回答，只说\(Self.languageName(config.theirLanguage))。
        通话目标：\(config.goal)
        原始参考资料（没有的事实不要编造）：\(config.materials)
        不要朗读识别过程、说明、JSON、中文释义或双语字幕。简短回答对方，等待对方说完；不要自问自答。
        最新人工接管记录具有最高优先级：以下记录中的新决定、新时间和修正覆盖原始参考资料的旧信息。
        \(manual.isEmpty ? "（尚无人工变更）" : manual)
        """
    }

    // MARK: - replying

    private func cancelReply() {
        generation &+= 1
        replyTask?.cancel()
        replyTask = nil
        if let pending = pendingTurn {
            pendingTurn = nil
            let heard = pending.audio.withLock { state in
                state.active = false
                return state.heard
            }
            if !heard { withdraw(pending.turn, at: pending.index) }
        }
    }

    private func scheduleReply(after delay: Duration) {
        cancelReply()
        let expected = generation
        let sleep = services.sleep
        replyTask = Task { [weak self] in
            if delay > .zero { try? await sleep(delay) }
            guard !Task.isCancelled else { return }
            await self?.reply(generation: expected)
        }
    }

    private func flushUnanswered() {
        guard !unanswered.isEmpty else { return }
        history.append(.init(role: .user, content: unanswered.joined(separator: " ")))
        unanswered.removeAll()
    }

    private func reply(generation expected: Int) async {
        guard let config, generation == expected else { return }
        flushUnanswered()
        phase = .thinking
        var messages = [ChatCompletionClient.Message(role: .system, content: Self.systemPrompt(config))]
        messages += history
        if history.isEmpty {
            messages.append(ChatCompletionClient.Message(role: .user, content: Self.openingCue))
        }
        let raw: String
        do {
            raw = try await services.complete(messages, config.chat)
        } catch {
            guard generation == expected else { return }
            BridgeLog.socket.error("agent chat failed: \(error.localizedDescription, privacy: .public)")
            replyTask = nil
            phase = .failed(error.localizedDescription)
            return
        }
        guard generation == expected, !Task.isCancelled else { return }
        let turn = Self.parseTurn(raw)
        guard !turn.say.isEmpty else {
            replyTask = nil
            phase = .failed("chat reply had no content")
            return
        }
        let turnIndex = history.count
        history.append(.init(role: .assistant, content: turn.say))
        lastLocal = nil
        onTurn?(turn)
        phase = .speaking

        let onAudio = self.onAudio
        let audioState = OSAllocatedUnfairLock(initialState: AudioState())
        pendingTurn = (turn, turnIndex, audioState)
        var failure: (any Error)?
        do {
            try await services.synthesize(
                turn.say, config.speakerID, Self.synthesisLanguage(config.theirLanguage), config.speech
            ) { pcm in
                audioState.withLock { state in
                    guard state.active else { return }
                    state.heard = true
                    onAudio?(pcm)
                }
            }
        } catch {
            failure = error
        }
        // A canceled provider may still return. It cannot mutate the history
        // or callbacks belonging to the next reply or rebuilt conversation.
        guard generation == expected else { return }
        pendingTurn = nil
        let heard = audioState.withLock { state in
            state.active = false
            return state.heard
        }
        // Once any of it played, the far end heard it — part of a reply is
        // still something we said. Before that, it was never said at all.
        if !heard { withdraw(turn, at: turnIndex) }
        if let failure {
            BridgeLog.socket.error("agent speech failed: \(failure.localizedDescription, privacy: .public)")
            replyTask = nil
            phase = .failed(failure.localizedDescription)
            return
        }
        onSpeechEnd?()
        replyTask = nil
        phase = turn.hangsUp ? .handedOver : .listening
        if phase == .listening, !unanswered.isEmpty { scheduleReply(after: replyDelay) }
    }

    private func withdraw(_ turn: Turn, at index: Int) {
        guard history.indices.contains(index), history[index].role == .assistant,
              history[index].content == turn.say else { return }
        history.remove(at: index)
        if let last = lastLocal, last.index > index { lastLocal = (last.utterance, last.index - 1) }
        onTurnWithdrawn?(turn)
    }

    // MARK: - prompt

    /// Stands in for the far end's first words when the agent opens the call.
    static let openingCue = "（电话已接通，对方还没有说话。请先开口问候并说明来意。）"

    static func systemPrompt(_ config: Config) -> String {
        let theirs = languageName(config.theirLanguage)
        let mine = languageName(config.myLanguage)
        let goal = config.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let materials = config.materials.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        你正在替用户本人打一通电话。请以用户本人的第一人称说话，不要提及自己是 AI 或助手。
        通话目标：\(goal.isEmpty ? "根据参考资料，礼貌、高效地完成沟通。" : goal)
        参考资料（只依据这些信息作答；资料里没有的事实不要编造，可以说"这个我确认一下再回复您"）：
        \(materials.isEmpty ? "（无）" : materials)

        对方说\(theirs)。每次回复都用\(theirs)，口语化，一到两句话，适合在电话里直接说出口；不要使用列表、表情或括号说明。
        历史里的 assistant 消息就是你（或用户本人）已经对对方说过的话，user 消息是对方说的话。
        只输出一个 JSON 对象，不要输出其他内容：
        {"say": "用\(theirs)说给对方的话", "gloss": "把 say 翻译成\(mine)给用户本人看", "hang_up": false}
        目标已经达成、并且双方已经道别时，hang_up 设为 true。
        """
    }

    static func languageName(_ code: String) -> String {
        let names = ["zh": "中文", "en": "英语", "ja": "日语", "ko": "韩语", "fr": "法语",
                     "de": "德语", "es": "西班牙语", "ru": "俄语", "pt": "葡萄牙语", "id": "印尼语"]
        return names[code] ?? code
    }

    /// The `explicit_language` the synthesiser takes, for the languages it
    /// names; others are left for it to infer from the text.
    static func synthesisLanguage(_ code: String) -> String? {
        let codes = ["zh": "zh-cn", "en": "en", "ja": "ja", "es": "es-mx",
                     "pt": "pt-br", "id": "id", "ko": "ko"]
        return codes[code]
    }

    /// Reads the model's JSON, tolerating prose or code fences around it. A
    /// reply that is not JSON at all is spoken as it stands.
    static func parseTurn(_ raw: String) -> Turn {
        if let open = raw.firstIndex(of: "{"), let close = raw.lastIndex(of: "}"), open < close,
           let object = try? JSONSerialization.jsonObject(
               with: Data(raw[open...close].utf8)) as? [String: Any],
           let say = object["say"] as? String {
            return Turn(
                say: say.trimmingCharacters(in: .whitespacesAndNewlines),
                gloss: (object["gloss"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                hangsUp: object["hang_up"] as? Bool ?? false
            )
        }
        return Turn(say: raw.trimmingCharacters(in: .whitespacesAndNewlines), gloss: "", hangsUp: false)
    }

    #if DEBUG
    var historyForTesting: [ChatCompletionClient.Message] { history }
    var unansweredForTesting: [String] { unanswered }
    var configForTesting: Config? { config }
    var realtimeInstructionsForTesting: String? { config.map { realtimeInstructions($0) } }
    #endif
}
