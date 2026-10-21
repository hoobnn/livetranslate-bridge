import os
import Foundation
import Observation

/// Holds up the user's side of a call on their behalf, from reference
/// material they supply, until they take over.
///
/// It listens to the far end through the remote lane's finished sentences,
/// answers through a chat model, and speaks the answer in the user's cloned
/// voice into the same output the user's own translated speech goes to. The
/// far end therefore hears one voice throughout: the agent's turns and the
/// user's own, translated, are the same timbre (see
/// `CredentialStore.DoubaoCredentials.cloneSpeakerID`).
///
/// Taking over is immediate: the moment the user starts speaking — or
/// presses Take Over — the agent stops talking, drops any reply it was
/// preparing, and stays quiet until handed the call back. What the user said
/// meanwhile is kept in its history, so it resumes knowing what was agreed.
@Observable
final class CallAgent {
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
    }

    private(set) var phase: Phase = .off

    /// How long the far end must stay quiet after a sentence before the
    /// agent answers. Long enough not to talk over a pause mid-thought, short
    /// enough not to leave dead air on the line.
    @ObservationIgnored var replyDelay: Duration = .milliseconds(900)

    @ObservationIgnored var onTurn: ((Turn) -> Void)?
    @ObservationIgnored var onAudio: (@Sendable (Data) -> Void)?
    /// The current reply's audio must stop now.
    @ObservationIgnored var onInterrupt: (() -> Void)?
    /// A reply finished streaming.
    @ObservationIgnored var onSpeechEnd: (() -> Void)?

    @ObservationIgnored private var config: Config?
    @ObservationIgnored private var history: [ChatCompletionClient.Message] = []
    @ObservationIgnored private var unanswered: [String] = []
    @ObservationIgnored private var replyTask: Task<Void, Never>?
    /// Bumped by everything that invalidates a reply in flight.
    @ObservationIgnored private var generation = 0

    /// Starts a call. Replies only after the far end speaks first, which is
    /// how a call one answers goes; use `speakFirst` to open it instead.
    func begin(_ config: Config) {
        self.config = config
        history = []
        unanswered = []
        generation &+= 1
        phase = .listening
    }

    func end() {
        cancelReply()
        config = nil
        phase = .off
    }

    /// Opens the call with a greeting written from the goal.
    func speakFirst() {
        guard phase == .listening else { return }
        scheduleReply(after: .zero)
    }

    // MARK: - what the call hears

    /// The far end started a sentence. A reply still being written answers
    /// what they said before it, so it is thrown away and rewritten once
    /// they finish.
    func noteRemoteSpeechStarted() {
        guard phase == .thinking || (phase == .listening && replyTask != nil) else { return }
        cancelReply()
        phase = .listening
    }

    func noteRemote(_ sentence: String) {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard config != nil, !text.isEmpty else { return }
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
    /// the translation is known.
    func noteLocal(_ sentence: String) {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard config != nil, !text.isEmpty else { return }
        flushUnanswered()
        history.append(.init(role: .assistant, content: text))
    }

    func takeOver() {
        guard config != nil else { return }
        cancelReply()
        onInterrupt?()
        phase = .handedOver
    }

    func handBack() {
        guard config != nil, phase == .handedOver || isFailed else { return }
        phase = .listening
        if !unanswered.isEmpty { scheduleReply(after: replyDelay) }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    // MARK: - replying

    private func cancelReply() {
        generation &+= 1
        replyTask?.cancel()
        replyTask = nil
    }

    private func scheduleReply(after delay: Duration) {
        cancelReply()
        let expected = generation
        replyTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
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
            raw = try await ChatCompletionClient.complete(messages, credentials: config.chat)
        } catch {
            guard generation == expected else { return }
            BridgeLog.socket.error("agent chat failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
            return
        }
        guard generation == expected, !Task.isCancelled else { return }
        let turn = Self.parseTurn(raw)
        guard !turn.say.isEmpty else { phase = .listening; return }
        history.append(.init(role: .assistant, content: turn.say))
        onTurn?(turn)
        phase = .speaking

        let onAudio = self.onAudio
        do {
            try await DoubaoVoiceServices.synthesize(
                text: turn.say, speaker: config.speakerID,
                language: Self.synthesisLanguage(config.theirLanguage),
                credentials: config.speech
            ) { pcm in onAudio?(pcm) }
        } catch is CancellationError {
            return
        } catch {
            guard generation == expected else { return }
            BridgeLog.socket.error("agent speech failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
            return
        }
        guard generation == expected else { return }
        onSpeechEnd?()
        replyTask = nil
        phase = turn.hangsUp ? .handedOver : .listening
        if phase == .listening, !unanswered.isEmpty { scheduleReply(after: replyDelay) }
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
        你正在替用户本人打一通电话。对方听到的是用户本人的声音（已克隆），所以请以用户本人的第一人称说话，不要提及自己是 AI 或助手。
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
        ["zh", "en", "ja"].contains(code) ? code : nil
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
    #endif
}
