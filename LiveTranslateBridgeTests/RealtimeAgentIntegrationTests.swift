import AVFoundation
import Foundation
import os
import Testing
@testable import LiveTranslateBridge

private nonisolated final class RealtimeAgentFixture: CallAgentRealtimeSession, @unchecked Sendable {
    struct State {
        var callback: (@Sendable (DoubaoRealtimeClient.Event) -> Void)?
        var audio = Data()
        var instructions: [String] = []
        var contexts: [[DoubaoRealtimeClient.ContextItem]] = []
        var muted: [Bool] = []
        var canceled = 0
        var aborted = 0
        var connected = 0
        var spoken: [String] = []
        var initialInstructions: [String] = []
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    var onEvent: (@Sendable (DoubaoRealtimeClient.Event) -> Void)? {
        get { state.withLock { $0.callback } }
        set { state.withLock { $0.callback = newValue } }
    }
    func connect() { state.withLock { $0.connected += 1 } }
    func appendAudio(_ pcm: Data) { state.withLock { $0.audio.append(pcm) } }
    func cancelResponse() { state.withLock { $0.canceled += 1 } }
    func setMuted(_ muted: Bool) { state.withLock { $0.muted.append(muted) } }
    func updateInstructions(_ instructions: String) { state.withLock { $0.instructions.append(instructions) } }
    func injectContext(_ items: [DoubaoRealtimeClient.ContextItem]) { state.withLock { $0.contexts.append(items) } }
    func speak(_ text: String) { state.withLock { $0.spoken.append(text) } }
    func abort() { state.withLock { $0.aborted += 1 } }
    func emit(_ kind: DoubaoRealtimeClient.Event.Kind, text: String? = nil,
              audio: Data? = nil, final: Bool = false, response: String? = nil) {
        onEvent?(.init(kind: kind, responseID: response, text: text, audio: audio, isFinal: final))
    }
}

@MainActor
struct RealtimeAgentIntegrationTests {
    private func config() -> CallAgent.Config {
        .init(materials: "Order A123 arrives at 3 PM", goal: "Confirm delivery",
              theirLanguage: "en", myLanguage: "zh", chat: .init(),
              speech: .init(appID: "", accessToken: "fixture"), speakerID: "unused",
              backend: .doubaoRealtime)
    }

    private func services(_ session: RealtimeAgentFixture) -> CallAgent.Services {
        .init(complete: { _, _ in Issue.record("Realtime called the legacy chat model"); return "" },
              synthesize: { _, _, _, _, _ in Issue.record("Realtime called standalone TTS") },
              makeRealtime: { config in
                  session.state.withLock { $0.initialInstructions.append(config.instructions) }
                  return session
              })
    }

    private func drain() async { for _ in 0..<100 { await Task.yield() } }

    @Test func aFreshModelDefaultsToRealtimeWithItsOwnJupiterVoice() {
        SubtitleModel.withTemporaryDefaults {
            let model = SubtitleModel()
            #expect(model.agentBackend == .doubaoRealtime)
            #expect(model.agentRealtimeVoice == DoubaoRealtimeClient.defaultVoice)
            model.agentBackend = .chatAndTTS
            model.agentRealtimeVoice = "custom-realtime"
            let restored = SubtitleModel()
            #expect(restored.agentBackend == .chatAndTTS)
            #expect(restored.agentRealtimeVoice == "custom-realtime")
        }
    }

    @Test func realtimeConsumesPCMWithoutAChatKeyAndStreamsOneSpokenSubtitle() async {
        let session = RealtimeAgentFixture()
        let agent = CallAgent(services: services(session))
        defer { agent.end() }
        var turns: [CallAgent.Turn] = []
        var endings = 0
        let audio = OSAllocatedUnfairLock(initialState: Data())
        agent.onTurn = { turns.append($0) }
        agent.onTurnUpdated = { previous, next in
            #expect(turns.last == previous)
            turns[turns.count - 1] = next
        }
        agent.onAudio = { pcm in audio.withLock { $0.append(pcm) } }
        agent.onSpeechEnd = { endings += 1 }
        agent.begin(config())
        session.emit(.ready)
        await drain()
        let pcm = Data([0, 0, 1, 0])
        agent.appendRemoteAudio(pcm)
        #expect(session.state.withLock { $0.audio } == pcm)
        session.emit(.sourceSpeechStarted)
        session.emit(.sourceTranscript, text: "What time?", final: true)
        session.emit(.responseText, text: "", response: "r1")
        session.emit(.responseText, text: "At ", response: "r1")
        session.emit(.responseText, text: "three.", response: "r1")
        session.emit(.responseText, text: "At three.", final: true, response: "r1")
        session.emit(.audio, audio: pcm, response: "r1")
        session.emit(.audioComplete, response: "r1")
        session.emit(.responseDone, response: "r1")
        await drain()
        #expect(agent.phase == .listening)
        #expect(turns == [.init(say: "At three.", gloss: "", hangsUp: false)])
        #expect(audio.withLock { $0 } == pcm)
        #expect(endings == 1)
        #expect(agent.historyForTesting.map(\.content) == ["What time?", "At three."])
    }

    @Test func takingOverMutesAndCancelsThenInjectsOnlyCompleteManualQAOnHandback() async {
        let session = RealtimeAgentFixture()
        let agent = CallAgent(services: services(session))
        defer { agent.end() }
        let audio = OSAllocatedUnfairLock(initialState: Data())
        agent.onAudio = { pcm in audio.withLock { $0.append(pcm) } }
        agent.begin(config())
        session.emit(.ready)
        await drain()
        session.emit(.sourceTranscript, text: "At three?", final: true)
        session.emit(.responseText, text: "Yes.", final: true, response: "old")
        await drain()
        let staleCallback = session.onEvent
        agent.takeOver()
        #expect(agent.phase == .handedOver)
        #expect(session.state.withLock { $0.canceled } == 1)
        #expect(session.state.withLock { $0.muted } == [true])
        agent.noteLocal("Please move it to four.", utterance: "local-1")
        agent.noteLocal("Please move it to four PM.", utterance: "local-1")
        agent.noteRemote("Anything else?")
        session.emit(.audio, audio: Data([1, 2]), response: "old")
        agent.handBack()
        session.emit(.ready)
        await drain()
        #expect(audio.withLock { $0 }.isEmpty)
        #expect(session.state.withLock { $0.muted } == [true])
        let pairs = session.state.withLock { $0.contexts.last ?? [] }
        #expect(pairs.map(\.role) == [.user, .assistant])
        #expect(pairs.map(\.text) == ["At three?", "Please move it to four PM."])
        #expect(session.state.withLock { $0.initialInstructions.last ?? "" }.contains("four PM"))
        #expect(session.state.withLock { $0.initialInstructions.last ?? "" }.contains("最高优先级"))
        #expect(session.state.withLock { $0.spoken }.isEmpty)
        staleCallback?(.init(kind: .audio, responseID: "old", audio: Data([3, 4])))
        await drain()
        #expect(audio.withLock { $0 }.isEmpty)
        session.emit(.sourceSpeechStarted)
        session.emit(.responseText, text: "Four is confirmed.", final: true, response: "new")
        session.emit(.audio, audio: Data([5, 6]), response: "new")
        await drain()
        #expect(audio.withLock { $0 } == Data([5, 6]))
        agent.updateBrief(materials: "Updated order information", goal: "Confirm the new time")
        #expect(session.state.withLock { $0.instructions }.isEmpty)
        #expect(!session.state.withLock { $0.initialInstructions.last ?? "" }.contains("Updated order information"))
        agent.takeOver()
        agent.handBack()
        #expect(session.state.withLock { $0.initialInstructions.last ?? "" }.contains("Updated order information"))
        #expect(session.state.withLock { $0.initialInstructions.last ?? "" }.contains("four PM"))
    }

    @Test func stoppedAndRebuiltConnectionsRejectRetainedOldCallbacksAndOldAudioSink() async {
        let first = RealtimeAgentFixture()
        let second = RealtimeAgentFixture()
        let sessions = OSAllocatedUnfairLock(initialState: [first, second])
        let agent = CallAgent(services: .init(makeRealtime: { _ in sessions.withLock { $0.removeFirst() } }))
        let audio = OSAllocatedUnfairLock(initialState: Data())
        agent.onAudio = { pcm in audio.withLock { $0.append(pcm) } }
        agent.begin(config())
        let oldCallback = first.onEvent
        let sink = agent.realtimeAudioSink()
        agent.end()
        sink?(Data([1, 2]))
        #expect(first.state.withLock { $0.audio }.isEmpty)
        agent.begin(config(), resuming: true)
        defer { agent.end() }
        oldCallback?(.init(kind: .audio, responseID: "stale", audio: Data([3, 4])))
        oldCallback?(.init(kind: .failed, text: "stale failure"))
        second.emit(.ready)
        await drain()
        sink?(Data([5, 6]))
        second.emit(.sourceSpeechStarted)
        second.emit(.responseText, text: "Fresh reply", final: true, response: "fresh")
        second.emit(.audio, audio: Data([7, 8]), response: "fresh")
        await drain()
        #expect(first.state.withLock { $0.aborted } == 1)
        #expect(second.state.withLock { $0.audio } == Data([5, 6]))
        #expect(audio.withLock { $0 } == Data([7, 8]))
        #expect(agent.phase == .speaking)
        #expect(agent.historyForTesting.allSatisfy { !$0.content.contains("stale") })
    }

    @Test func productSetupUsesSpeechKeyOnlyAndRoutesRawPCMIncludingSilenceToRealtime() async throws {
        let session = RealtimeAgentFixture()
        var model: SubtitleModel!
        SubtitleModel.withTemporaryDefaults {
            model = SubtitleModel(agent: CallAgent(services: services(session)))
            model.agentEnabled = true
            model.agentBackend = .doubaoRealtime
            model.provider = .doubao
            model.myLanguage = "zh"
            model.theirLanguage = "en"
            model.beginForTesting()
        }
        let player = TranslationPlayer(manualRendering: true)
        try player.start(device: nil)
        defer { model.stop(); player.stop() }
        await model.beginAgentForTesting(chat: .init(), speech: .init(appID: "", accessToken: "fixture"), player: player)
        session.emit(.ready)
        await drain()
        #expect(model.agent.phase == .listening)
        #expect(model.audioNotice == nil)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 640))
        buffer.frameLength = 640
        buffer.floatChannelData![0].initialize(repeating: 0, count: 640)
        model.feedAgentAudioForTesting(buffer)
        #expect(session.state.withLock { $0.audio.count } == 1_280)
        #expect(session.state.withLock { $0.audio.allSatisfy { $0 == 0 } })
        session.emit(.sourceSpeechStarted)
        session.emit(.responseText, text: "At four.", final: true, response: "r1")
        session.emit(.audio, audio: Data(repeating: 0, count: 4_800), response: "r1")
        session.emit(.audioComplete, response: "r1")
        session.emit(.responseDone, response: "r1")
        await drain()
        #expect(model.entries.filter(\.isAgent).map(\.translation) == ["At four."])
        #expect(model.entries.filter(\.isAgent).allSatisfy { $0.transcript.isEmpty })
        model.stop()
        let before = session.state.withLock { $0.audio.count }
        model.feedAgentAudioForTesting(buffer)
        #expect(session.state.withLock { $0.audio.count } == before)
    }

    @Test func unsupportedLanguageAndOldTokenAreRejectedBeforeConnecting() async {
        let session = RealtimeAgentFixture()
        var model: SubtitleModel!
        SubtitleModel.withTemporaryDefaults {
            model = SubtitleModel(agent: CallAgent(services: services(session)))
            model.agentEnabled = true
            model.agentBackend = .doubaoRealtime
            model.myLanguage = "zh"
            model.theirLanguage = "ja"
            model.beginForTesting()
        }
        defer { model.stop() }
        await model.beginAgentForTesting(chat: .init(), speech: .init(appID: "", accessToken: "fixture"))
        #expect(model.agent.phase == .off)
        #expect(model.audioNotice == t("agent.realtime.languages"))
        model.theirLanguage = "en"
        await model.beginAgentForTesting(chat: .init(), speech: .init(appID: "legacy", accessToken: "fixture"))
        #expect(model.agent.phase == .off)
        #expect(model.audioNotice == t("agent.realtime.needsAPIKey"))
        #expect(session.state.withLock { $0.connected } == 0)
    }

    @Test func takeoverPausesPCMAndEmptyHandbackDoesNotSendInvalidEmptyContext() async {
        let session = RealtimeAgentFixture()
        let agent = CallAgent(services: services(session))
        defer { agent.end() }
        agent.begin(config())
        session.emit(.ready)
        await drain()
        agent.appendRemoteAudio(Data([1, 2]))
        agent.takeOver()
        agent.appendRemoteAudio(Data([3, 4]))
        #expect(session.state.withLock { $0.audio } == Data([1, 2]))
        agent.handBack()
        session.emit(.ready)
        await drain()
        #expect(session.state.withLock { $0.contexts }.isEmpty)
        agent.appendRemoteAudio(Data([5, 6]))
        #expect(session.state.withLock { $0.audio } == Data([1, 2, 5, 6]))
    }

    @Test func resumedHistoryWaitsForReadyAndOnlySendsTheLatestTwentyCompletePairs() async {
        let session = RealtimeAgentFixture()
        let agent = CallAgent(services: services(session))
        defer { agent.end() }
        agent.begin(config())
        session.emit(.ready)
        await drain()
        agent.takeOver()
        for index in 0..<25 {
            agent.noteRemote("Question \(index)")
            agent.noteLocal("Answer \(index)", utterance: "u-\(index)")
        }
        agent.handBack()
        session.emit(.ready)
        await drain()
        let handback = session.state.withLock { $0.contexts.last ?? [] }
        #expect(handback.count == 40)
        #expect(handback.first?.text == "Question 5")
        #expect(handback.last?.text == "Answer 24")
        agent.end()
        let before = session.state.withLock { $0.contexts.count }
        agent.begin(config(), resuming: true)
        #expect(session.state.withLock { $0.contexts.count } == before)
        session.emit(.ready)
        await drain()
        #expect(session.state.withLock { $0.contexts.count } == before + 1)
        #expect(session.state.withLock { $0.contexts.last?.count } == 40)
    }

    @Test func emptyRealtimeVoiceInTheSameSettingsSessionUsesJupiter() async {
        let session = RealtimeAgentFixture()
        let voices = OSAllocatedUnfairLock(initialState: [String]())
        var model: SubtitleModel!
        SubtitleModel.withTemporaryDefaults {
            model = SubtitleModel(agent: CallAgent(services: .init(makeRealtime: { config in
                voices.withLock { $0.append(config.voice) }
                return session
            })))
            model.agentEnabled = true
            model.agentRealtimeVoice = "   "
            model.myLanguage = "zh"
            model.theirLanguage = "en"
            model.beginForTesting()
        }
        defer { model.stop() }
        await model.beginAgentForTesting(chat: .init(), speech: .init(appID: "", accessToken: "fixture"))
        #expect(voices.withLock { $0 } == [DoubaoRealtimeClient.defaultVoice])
    }

    @Test func aProactiveManualChangeRemainsAuthoritativeWithoutInventingAQuestion() async {
        let session = RealtimeAgentFixture()
        let agent = CallAgent(services: services(session))
        defer { agent.end() }
        agent.begin(config())
        session.emit(.ready)
        session.emit(.sourceTranscript, text: "What time?", final: true)
        session.emit(.responseText, text: "Three PM.", final: true, response: "r1")
        session.emit(.audio, audio: Data([1, 2]), response: "r1")
        session.emit(.responseDone, response: "r1")
        await drain()
        agent.takeOver()
        agent.noteLocal("Actually move it to four PM.", utterance: "manual")
        agent.handBack()
        #expect(session.state.withLock { $0.contexts }.isEmpty)
        #expect(session.state.withLock { $0.initialInstructions.last ?? "" }.contains("Actually move it to four PM."))
    }

    @Test func handbackCreatesAFreshSessionWithManualDecisionsInItsInitialInstructions() async {
        let first = RealtimeAgentFixture()
        let second = RealtimeAgentFixture()
        let pending = OSAllocatedUnfairLock(initialState: [first, second])
        let configurations = OSAllocatedUnfairLock(initialState: [DoubaoRealtimeClient.Config]())
        let agent = CallAgent(services: .init(makeRealtime: { config in
            configurations.withLock { $0.append(config) }
            return pending.withLock { $0.removeFirst() }
        }))
        let audio = OSAllocatedUnfairLock(initialState: Data())
        agent.onAudio = { pcm in audio.withLock { $0.append(pcm) } }
        agent.begin(config())
        first.emit(.ready)
        await drain()
        agent.takeOver()
        agent.noteRemote("Can you move it to four?")
        agent.noteLocal("Yes, four PM is confirmed.")
        let oldCallback = first.onEvent
        agent.handBack()
        defer { agent.end() }
        #expect(agent.isRealtimeConnecting)
        #expect(first.state.withLock { $0.aborted } == 1)
        #expect(second.state.withLock { $0.connected } == 1)
        #expect(configurations.withLock { $0.last?.instructions ?? "" }.contains("four PM is confirmed"))
        agent.appendRemoteAudio(Data([1, 2]))
        #expect(second.state.withLock { $0.audio }.isEmpty)
        #expect(second.state.withLock { $0.contexts }.isEmpty)
        oldCallback?(.init(kind: .audio, audio: Data([3, 4])))
        second.emit(.ready)
        await drain()
        #expect(!agent.isRealtimeConnecting)
        #expect(second.state.withLock { $0.contexts.last?.map(\.text) }
                == ["Can you move it to four?", "Yes, four PM is confirmed."])
        agent.appendRemoteAudio(Data([5, 6]))
        #expect(second.state.withLock { $0.audio } == Data([5, 6]))
        #expect(audio.withLock { $0 }.isEmpty)
    }

    @Test func aReadyEnrollmentRoutesItsReturnedVoiceIntoTheRealtimeSessionWithoutAChatKey() async throws {
        let session = RealtimeAgentFixture()
        let voices = OSAllocatedUnfairLock(initialState: [String]())
        let speech = CredentialStore.DoubaoCredentials(appID: "", accessToken: "fixture")
        var enrollment: RealtimeVoiceTrainingModel!
        var model: SubtitleModel!
        SubtitleModel.withTemporaryDefaults {
            enrollment = RealtimeVoiceTrainingModel(services: .init(train: { _, _, voice, _, language, _, requestID in
                #expect(voice == .custom("LiveTranslateTestVoice"))
                #expect(language == "en")
                #expect(UUID(uuidString: requestID) != nil)
                return .init(speakerID: "S_returned_realtime_voice", status: .ready,
                             remainingTrainingTimes: 14, language: 1, previews: [])
            }, query: { _, _ in
                Issue.record("A completed enrollment should not require an extra query")
                throw CancellationError()
            }), defaults: SubtitleModel.defaultsStoreForTesting)
            model = SubtitleModel(agent: CallAgent(services: .init(
                complete: { _, _ in Issue.record("Realtime enrollment must not call Chat"); return "" },
                synthesize: { _, _, _, _, _ in Issue.record("Realtime enrollment must not call standalone TTS") },
                makeRealtime: { config in
                    voices.withLock { $0.append(config.voice) }
                    return session
                }
            )))
            model.agentEnabled = true
            model.agentBackend = .doubaoRealtime
            model.myLanguage = "zh"
            model.theirLanguage = "en"
            model.beginForTesting()
        }
        defer { model.stop() }
        enrollment.voiceKind = .custom
        enrollment.voiceID = "LiveTranslateTestVoice"
        enrollment.language = "en"
        try enrollment.setSample(Data([1, 2]), format: "wav", fileName: "fixture.wav")
        await enrollment.submit(credentials: speech)
        let returnedVoiceID = try #require(enrollment.usableVoiceID())
        SubtitleModel.withTemporaryDefaults { model.agentRealtimeVoice = returnedVoiceID }
        await model.beginAgentForTesting(chat: .init(), speech: speech)
        #expect(voices.withLock { $0 } == ["S_returned_realtime_voice"])
        session.emit(.ready)
        await drain()
        #expect(model.agent.phase == .listening)
        #expect(model.audioNotice == nil)
    }
}
