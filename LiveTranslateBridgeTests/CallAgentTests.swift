//
//  CallAgentTests.swift
//  LiveTranslateBridgeTests
//

import Foundation
import os
import Testing
@testable import LiveTranslateBridge

@MainActor
struct CallAgentTests {
    private func config(materials: String = "订单号 A123，明天下午三点送达。") -> CallAgent.Config {
        .init(materials: materials, goal: "确认送货时间",
              theirLanguage: "en", myLanguage: "zh",
              chat: .init(apiKey: "k", model: "m"),
              speech: .init(appID: "", accessToken: "t"),
              speakerID: "S_test")
    }

    /// An agent that never actually replies: the delay outlasts the test.
    private func idleAgent() -> CallAgent {
        let agent = CallAgent()
        agent.replyDelay = .seconds(3_600)
        agent.begin(config())
        return agent
    }

    @Test func parsesTheModelsJSONEvenWithFences() {
        let turn = CallAgent.parseTurn("""
        ```json
        {"say": "It arrives tomorrow at three.", "gloss": "明天三点到。", "hang_up": false}
        ```
        """)
        #expect(turn == .init(say: "It arrives tomorrow at three.", gloss: "明天三点到。", hangsUp: false))
    }

    @Test func plainProseIsSpokenAsItStands() {
        #expect(CallAgent.parseTurn("  Sure, one moment. ").say == "Sure, one moment.")
    }

    @Test func promptCarriesGoalMaterialsAndLanguages() {
        let prompt = CallAgent.systemPrompt(config())
        #expect(prompt.contains("确认送货时间"))
        #expect(prompt.contains("订单号 A123"))
        #expect(prompt.contains("英语"))
        #expect(prompt.contains("\"say\""))
        #expect(!prompt.contains("已克隆"))
    }

    @Test func speakingTakesTheCallOverAndStopsTheAgentsAudio() {
        let agent = idleAgent()
        var interrupted = false
        agent.onInterrupt = { interrupted = true }
        agent.noteRemote("When will it arrive?")
        #expect(agent.unansweredForTesting == ["When will it arrive?"])
        agent.noteLocalSpeech()
        #expect(agent.phase == .handedOver)
        #expect(interrupted)
    }

    @Test func whatTheUserSaidIsRememberedForTheHandBack() {
        let agent = idleAgent()
        agent.noteRemote("Is three okay?")
        agent.takeOver()
        agent.noteLocal("Four would be better.")
        #expect(agent.historyForTesting.map(\.content) == ["Is three okay?", "Four would be better."])
        #expect(agent.historyForTesting.map(\.role) == [.user, .assistant])
        agent.handBack()
        #expect(agent.phase == .listening)
        agent.end()
        #expect(agent.phase == .off)
    }

    @Test func aSentenceTranslatedInPartsIsRememberedOnce() {
        let agent = idleAgent()
        agent.takeOver()
        agent.noteLocal("A long", utterance: "s/seg-1")
        agent.noteLocal("A long sentence", utterance: "s/seg-1")
        agent.noteLocal("Next one", utterance: "s/seg-2")
        #expect(agent.historyForTesting.map(\.content) == ["A long sentence", "Next one"])
        agent.end()
    }

    @Test func aRebuiltSessionKeepsTheConversation() {
        let agent = idleAgent()
        agent.noteRemote("Is Friday fine?")
        agent.end()
        agent.begin(config(), resuming: true)
        #expect(agent.unansweredForTesting == ["Is Friday fine?"])
        agent.begin(config())
        #expect(agent.unansweredForTesting.isEmpty)
        agent.end()
    }

    @Test func aCallWeTookOverStaysOursAcrossARebuild() {
        let agent = idleAgent()
        agent.takeOver()
        agent.end()
        agent.end()
        agent.begin(config(), resuming: true)
        #expect(agent.phase == .handedOver)
        agent.end()
        agent.begin(config())
        #expect(agent.phase == .listening)
        agent.end()
    }

    @Test func synthesisLanguagesUseTheServicesCodes() {
        #expect(CallAgent.synthesisLanguage("zh") == "zh-cn")
        #expect(CallAgent.synthesisLanguage("es") == "es-mx")
        #expect(CallAgent.synthesisLanguage("pt") == "pt-br")
        #expect(CallAgent.synthesisLanguage("fr") == nil)
    }

    @Test func editsToTheBriefReachTheRunningCall() {
        let agent = idleAgent()
        agent.updateBrief(materials: "价格 99 元", goal: "改约到周五")
        let prompt = agent.configForTesting.map(CallAgent.systemPrompt) ?? ""
        #expect(prompt.contains("价格 99 元"))
        #expect(prompt.contains("改约到周五"))
        agent.end()
    }

    @Test func theFarEndSpeakingAgainCancelsAPendingReply() {
        let agent = idleAgent()
        agent.noteRemote("Hello?")
        agent.noteRemoteSpeechStarted()
        #expect(agent.phase == .listening)
        // Still owed an answer once they finish.
        #expect(agent.unansweredForTesting == ["Hello?"])
        agent.end()
    }

    @Test func boardEventsReachTheAgent() {
        let model = SubtitleModel()
        model.agent.replyDelay = .seconds(3_600)
        model.agent.begin(config())
        model.observeForAgentForTesting(
            .identified(.init(streamID: "s", itemID: "seg-1"), .transcriptComplete("Hi there")),
            from: .remote
        )
        #expect(model.agent.unansweredForTesting == ["Hi there"])
        model.observeForAgentForTesting(.transcriptDelta("我"), from: .local)
        #expect(model.agent.phase == .handedOver)
        model.agent.end()
    }
}

/// The continuations deliberately ignore cancellation until released. This
/// catches stale provider callbacks even when a backend finishes late.
@MainActor
private final class CallAgentServiceHarness {
    struct Chat {
        var messages: [ChatCompletionClient.Message]
        var continuation: CheckedContinuation<String, any Error>?
    }
    struct Speech {
        var text: String
        var speaker: String
        var language: String?
        var onAudio: @Sendable (Data) -> Void
        var continuation: CheckedContinuation<Void, any Error>?
    }
    var chats: [Chat] = []
    var speeches: [Speech] = []
    var delays: [CheckedContinuation<Void, any Error>?] = []
    var cancelledChats: Set<Int> = []
    var cancelledSpeeches: Set<Int> = []
    var cancelledDelays: Set<Int> = []
    var turns: [CallAgent.Turn] = []
    var withdrawn: [CallAgent.Turn] = []
    var interruptions = 0
    var speechEnds = 0
    let audio = OSAllocatedUnfairLock(initialState: Data())

    func agent() -> CallAgent {
        let agent = CallAgent(services: .init(
            complete: { [self] messages, _ in try await chat(messages) },
            synthesize: { [self] text, speaker, language, _, onAudio in
                try await speech(text, speaker: speaker, language: language, onAudio: onAudio)
            },
            sleep: { [self] _ in try await delay() }
        ))
        agent.onTurn = { [self] in turns.append($0) }
        agent.onTurnWithdrawn = { [self] in withdrawn.append($0) }
        agent.onInterrupt = { [self] in interruptions += 1 }
        agent.onSpeechEnd = { [self] in speechEnds += 1 }
        let audio = audio
        agent.onAudio = { data in audio.withLock { $0.append(data) } }
        return agent
    }

    private func chat(_ messages: [ChatCompletionClient.Message]) async throws -> String {
        let index = chats.count
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                chats.append(Chat(messages: messages, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [self] in cancelledChats.insert(index) }
        }
    }

    private func speech(_ text: String, speaker: String, language: String?,
                        onAudio: @escaping @Sendable (Data) -> Void) async throws {
        let index = speeches.count
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                speeches.append(Speech(text: text, speaker: speaker, language: language,
                                       onAudio: onAudio, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [self] in cancelledSpeeches.insert(index) }
        }
    }

    private func delay() async throws {
        let index = delays.count
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in delays.append(continuation) }
        } onCancel: {
            Task { @MainActor [self] in cancelledDelays.insert(index) }
        }
    }

    func releaseDelay(_ index: Int) {
        let continuation = delays[index]
        delays[index] = nil
        continuation?.resume()
    }

    func finishChat(_ index: Int, _ result: Result<String, any Error> = .success(
        #"{"say":"Friday works.","gloss":"周五可以。","hang_up":false}"#
    )) {
        let continuation = chats[index].continuation
        chats[index].continuation = nil
        continuation?.resume(with: result)
    }

    func finishSpeech(_ index: Int, _ result: Result<Void, any Error> = .success(())) {
        let continuation = speeches[index].continuation
        speeches[index].continuation = nil
        continuation?.resume(with: result)
    }

    func cleanUp() {
        for index in delays.indices {
            delays[index]?.resume(throwing: CancellationError())
            delays[index] = nil
        }
        for index in chats.indices { finishChat(index, .failure(CancellationError())) }
        for index in speeches.indices { finishSpeech(index, .failure(CancellationError())) }
    }

    /// Actor turns, rather than elapsed time, advance each controlled request.
    func until(_ predicate: () -> Bool) async {
        for _ in 0..<10_000 {
            if predicate() { return }
            await Task.yield()
        }
        Issue.record("controlled agent operation did not reach its expected state")
    }

    func drain() async { for _ in 0..<30 { await Task.yield() } }
}

@MainActor
struct CallAgentLifecycleTests {
    private func config() -> CallAgent.Config {
        .init(materials: "Friday delivery, order A123", goal: "Confirm delivery",
              theirLanguage: "en", myLanguage: "zh", chat: .init(apiKey: "test", model: "test"),
              speech: .init(appID: "test", accessToken: "test"), speakerID: "S_test")
    }

    @Test func automaticReplyRunsChatAndSpeechThenReturnsToListening() async throws {
        let harness = CallAgentServiceHarness()
        let agent = harness.agent()
        defer { agent.end(); harness.cleanUp() }
        agent.begin(config())
        agent.noteRemote("Does Friday work?")
        await harness.until { harness.delays.count == 1 }
        harness.releaseDelay(0)
        await harness.until { harness.chats.count == 1 }
        #expect(agent.phase == .thinking)
        #expect(harness.chats[0].messages.map(\.role) == [.system, .user])
        #expect(harness.chats[0].messages.last?.content == "Does Friday work?")
        harness.finishChat(0)
        await harness.until { harness.speeches.count == 1 }
        #expect(agent.phase == .speaking)
        #expect(harness.speeches[0].speaker == "S_test")
        #expect(harness.speeches[0].language == "en")
        harness.speeches[0].onAudio(Data([1, 2, 3, 4]))
        harness.finishSpeech(0)
        await harness.until { agent.phase == .listening }
        #expect(harness.audio.withLock { $0 } == Data([1, 2, 3, 4]))
        #expect(harness.turns.map(\.say) == ["Friday works."])
        #expect(harness.speechEnds == 1)
        #expect(agent.historyForTesting.map(\.content) == ["Does Friday work?", "Friday works."])
    }

    @Test func continuingRemoteSpeechCancelsThePauseAndAnswersAllSentencesTogether() async throws {
        let harness = CallAgentServiceHarness()
        let agent = harness.agent()
        defer { agent.end(); harness.cleanUp() }
        agent.begin(config())
        agent.noteRemote("First question.")
        await harness.until { harness.delays.count == 1 }
        agent.noteRemoteSpeechStarted()
        harness.releaseDelay(0)
        await harness.drain()
        #expect(harness.chats.isEmpty)
        agent.noteRemote("And a second question.")
        await harness.until { harness.delays.count == 2 }
        harness.releaseDelay(1)
        await harness.until { harness.chats.count == 1 }
        #expect(harness.chats[0].messages.last?.content == "First question. And a second question.")
        #expect(harness.cancelledDelays.contains(0))
    }

    @Test func remoteInterruptDuringThinkingCancelsTheOldRequestAndKeepsItsContext() async throws {
        let harness = CallAgentServiceHarness()
        let agent = harness.agent()
        defer { agent.end(); harness.cleanUp() }
        agent.replyDelay = .zero
        agent.begin(config())
        agent.noteRemote("First question.")
        await harness.until { harness.chats.count == 1 }
        agent.noteRemoteSpeechStarted()
        agent.noteRemote("More detail.")
        await harness.until { harness.chats.count == 2 }
        harness.finishChat(0)
        await harness.drain()
        #expect(harness.speeches.isEmpty)
        #expect(harness.cancelledChats.contains(0))
        #expect(harness.chats[1].messages.filter { $0.role == .user }.map(\.content)
                == ["First question.", "More detail."])
    }

    @Test func remoteInterruptStopsLateAudioButKeepsAnAlreadyHeardTurn() async throws {
        let harness = CallAgentServiceHarness()
        let agent = harness.agent()
        defer { agent.end(); harness.cleanUp() }
        agent.replyDelay = .zero
        agent.begin(config())
        agent.noteRemote("Friday?")
        await harness.until { harness.chats.count == 1 }
        harness.finishChat(0)
        await harness.until { harness.speeches.count == 1 }
        harness.speeches[0].onAudio(Data([1, 2]))
        agent.noteRemoteSpeechStarted()
        harness.speeches[0].onAudio(Data([3, 4]))
        harness.finishSpeech(0)
        await harness.drain()
        #expect(harness.audio.withLock { $0 } == Data([1, 2]))
        #expect(harness.interruptions == 1)
        #expect(harness.cancelledSpeeches.contains(0))
        #expect(harness.withdrawn.isEmpty)
        #expect(agent.historyForTesting.last?.content == "Friday works.")
        #expect(agent.phase == .listening)
        #expect(harness.speechEnds == 0)
    }

    @Test func userTakeoverWithdrawsUnheardSpeechImmediatelyAndHandBackKeepsHistory() async throws {
        let harness = CallAgentServiceHarness()
        let agent = harness.agent()
        defer { agent.end(); harness.cleanUp() }
        agent.replyDelay = .zero
        agent.begin(config())
        agent.noteRemote("Friday?")
        await harness.until { harness.chats.count == 1 }
        harness.finishChat(0)
        await harness.until { harness.speeches.count == 1 }
        agent.noteLocalSpeech()
        #expect(agent.phase == .handedOver)
        #expect(harness.withdrawn.count == 1)
        #expect(agent.historyForTesting.map(\.content) == ["Friday?"])
        agent.noteLocal("Saturday is better.", utterance: "local-1")
        agent.noteRemote("Saturday at three?")
        agent.handBack()
        await harness.until { harness.chats.count == 2 }
        #expect(harness.chats[1].messages.dropFirst().map(\.content)
                == ["Friday?", "Saturday is better.", "Saturday at three?"])
        harness.speeches[0].onAudio(Data([1, 2]))
        harness.finishSpeech(0, .failure(CancellationError()))
        await harness.drain()
        #expect(harness.audio.withLock { $0 }.isEmpty)
        #expect(harness.withdrawn.count == 1)
    }

    @Test func rebuildingDirectlyCancelsOldSpeechAndItsLateCompletionCannotRemoveTheNewTurn() async throws {
        let harness = CallAgentServiceHarness()
        let agent = harness.agent()
        defer { agent.end(); harness.cleanUp() }
        agent.replyDelay = .zero
        agent.begin(config())
        agent.noteRemote("Old question")
        await harness.until { harness.chats.count == 1 }
        harness.finishChat(0)
        await harness.until { harness.speeches.count == 1 }
        agent.begin(config())
        await harness.drain()
        #expect(harness.cancelledSpeeches.contains(0))
        agent.noteRemote("New question")
        await harness.until { harness.chats.count == 2 }
        harness.finishChat(1)
        await harness.until { harness.speeches.count == 2 }
        harness.speeches[0].onAudio(Data([1, 2]))
        harness.finishSpeech(0)
        await harness.drain()
        #expect(harness.audio.withLock { $0 }.isEmpty)
        #expect(agent.historyForTesting.map(\.content) == ["New question", "Friday works."])
        #expect(agent.phase == .speaking)
    }

    @Test func stoppedThinkingIsCancelledAndResumeRetriesTheOwedReply() async throws {
        let harness = CallAgentServiceHarness()
        let agent = harness.agent()
        defer { agent.end(); harness.cleanUp() }
        agent.replyDelay = .zero
        agent.begin(config())
        agent.noteRemote("Please confirm.")
        await harness.until { harness.chats.count == 1 }
        agent.end()
        #expect(agent.phase == .off)
        agent.begin(config(), resuming: true)
        await harness.until { harness.chats.count == 2 }
        #expect(harness.cancelledChats.contains(0))
        #expect(harness.chats[1].messages.last?.content == "Please confirm.")
        harness.finishChat(0)
        await harness.drain()
        #expect(harness.speeches.isEmpty)
    }

    @Test func chatAndUnheardSpeechFailuresCanBeRetriedWithoutPhantomTurns() async throws {
        let harness = CallAgentServiceHarness()
        let agent = harness.agent()
        defer { agent.end(); harness.cleanUp() }
        agent.replyDelay = .zero
        agent.begin(config())
        agent.noteRemote("Friday?")
        await harness.until { harness.chats.count == 1 }
        harness.finishChat(0, .failure(ChatCompletionClient.ServiceError(message: "chat unavailable")))
        await harness.until { if case .failed = agent.phase { true } else { false } }
        agent.handBack()
        await harness.until { harness.chats.count == 2 }
        harness.finishChat(1)
        await harness.until { harness.speeches.count == 1 }
        harness.finishSpeech(0, .failure(DoubaoVoiceServices.ServiceError(message: "speech unavailable")))
        await harness.until { if case .failed = agent.phase { true } else { false } }
        #expect(harness.withdrawn.count == 1)
        #expect(agent.historyForTesting.map(\.content) == ["Friday?"])
        agent.handBack()
        await harness.until { harness.chats.count == 3 }
        harness.finishChat(2)
        await harness.until { harness.speeches.count == 2 }
        harness.speeches[1].onAudio(Data([1, 2]))
        harness.finishSpeech(1)
        await harness.until { agent.phase == .listening }
        #expect(agent.historyForTesting.map(\.content) == ["Friday?", "Friday works."])
        #expect(harness.withdrawn.count == 1)
    }

    @Test func openingCanFinishTheConversationWithoutWaitingForRemoteSpeech() async throws {
        let harness = CallAgentServiceHarness()
        let agent = harness.agent()
        defer { agent.end(); harness.cleanUp() }
        agent.begin(config())
        agent.speakFirst()
        await harness.until { harness.chats.count == 1 }
        #expect(harness.chats[0].messages.last?.content == CallAgent.openingCue)
        harness.finishChat(0, .success(#"{"say":"Goodbye.","gloss":"再见。","hang_up":true}"#))
        await harness.until { harness.speeches.count == 1 }
        harness.speeches[0].onAudio(Data([1, 2]))
        harness.finishSpeech(0)
        await harness.until { agent.phase == .handedOver }
        #expect(harness.speechEnds == 1)
    }

    @Test func endingUnheardSpeechInterruptsAndLeavesTheReplyOwedAcrossResume() async throws {
        let harness = CallAgentServiceHarness()
        let agent = harness.agent()
        defer { agent.end(); harness.cleanUp() }
        agent.replyDelay = .zero
        agent.begin(config())
        agent.noteRemote("Friday?")
        await harness.until { harness.chats.count == 1 }
        harness.finishChat(0)
        await harness.until { harness.speeches.count == 1 }
        agent.end()
        #expect(harness.interruptions == 1)
        #expect(harness.withdrawn.count == 1)
        #expect(agent.historyForTesting.map(\.content) == ["Friday?"])
        agent.begin(config(), resuming: true)
        await harness.until { harness.chats.count == 2 }
        harness.speeches[0].onAudio(Data([1, 2]))
        harness.finishSpeech(0, .failure(CancellationError()))
        await harness.drain()
        #expect(harness.audio.withLock { $0 }.isEmpty)
        #expect(harness.chats[1].messages.last?.content == "Friday?")
        #expect(harness.withdrawn.count == 1)
    }

    @Test func aPartialSpeechFailureKeepsTheHeardTurnAndDoesNotRepeatItOnHandBack() async throws {
        let harness = CallAgentServiceHarness()
        let agent = harness.agent()
        defer { agent.end(); harness.cleanUp() }
        agent.replyDelay = .zero
        agent.begin(config())
        agent.noteRemote("Friday?")
        await harness.until { harness.chats.count == 1 }
        harness.finishChat(0)
        await harness.until { harness.speeches.count == 1 }
        harness.speeches[0].onAudio(Data([1, 2]))
        harness.finishSpeech(0, .failure(DoubaoVoiceServices.ServiceError(message: "stream lost")))
        await harness.until { if case .failed = agent.phase { true } else { false } }
        #expect(harness.withdrawn.isEmpty)
        #expect(agent.historyForTesting.last?.content == "Friday works.")
        agent.handBack()
        await harness.drain()
        #expect(agent.phase == .listening)
        #expect(harness.chats.count == 1)
    }

    @Test func remoteSpeechInterruptsPlaybackEvenAfterSynthesisFinishedStreaming() async throws {
        let harness = CallAgentServiceHarness()
        let agent = harness.agent()
        defer { agent.end(); harness.cleanUp() }
        agent.replyDelay = .zero
        agent.begin(config())
        agent.noteRemote("Friday?")
        await harness.until { harness.chats.count == 1 }
        harness.finishChat(0)
        await harness.until { harness.speeches.count == 1 }
        harness.speeches[0].onAudio(Data([1, 2]))
        harness.finishSpeech(0)
        await harness.until { agent.phase == .listening }
        agent.noteRemoteSpeechStarted()
        #expect(harness.interruptions == 1)
        #expect(agent.phase == .listening)
        agent.takeOver()
        let before = harness.interruptions
        agent.noteRemoteSpeechStarted()
        #expect(harness.interruptions == before)
        #expect(agent.phase == .handedOver)
    }

    @Test func anEmptyProposedTurnFailsAndRemainsRetryable() async throws {
        let harness = CallAgentServiceHarness()
        let agent = harness.agent()
        defer { agent.end(); harness.cleanUp() }
        agent.replyDelay = .zero
        agent.begin(config())
        agent.noteRemote("Friday?")
        await harness.until { harness.chats.count == 1 }
        harness.finishChat(0, .success(#"{"say":"  ","gloss":"","hang_up":false}"#))
        await harness.drain()
        #expect({ if case .failed = agent.phase { true } else { false } }())
        #expect(harness.speeches.isEmpty)
        #expect(agent.historyForTesting.map(\.content) == ["Friday?"])
        agent.handBack()
        await harness.drain()
        #expect(harness.chats.count == 2)
    }
}

/// Each test supplies its response through its own session, so parallel tests
/// cannot consume one another's fixtures or reach the network.
private final class SpeechResponseProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let status = Int(request.value(forHTTPHeaderField: "X-Test-Status") ?? "200") ?? 200
        let body = Data(base64Encoded: request.value(forHTTPHeaderField: "X-Test-Body") ?? "") ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct DoubaoVoiceHTTPTests {
    private let credentials = CredentialStore.DoubaoCredentials(appID: "test-app", accessToken: "test-token")

    private func session(_ body: String, status: Int = 200) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SpeechResponseProtocol.self]
        config.httpAdditionalHeaders = [
            "X-Test-Body": Data(body.utf8).base64EncodedString(),
            "X-Test-Status": String(status),
        ]
        return URLSession(configuration: config)
    }

    @Test(arguments: [
        "", "not JSON", #"{"code":0,"data":"%%%"}"#,
        #"{"data":"AQIDBA=="}"#,
        #"{"code":0,"data":"AQIDBA=="}"#,
        #"{"code":20000000}"#,
    ])
    func incompleteOrMalformedSynthesisFails(_ body: String) async {
        let session = session(body)
        defer { session.invalidateAndCancel() }
        await #expect(throws: DoubaoVoiceServices.ServiceError.self) {
            try await DoubaoVoiceServices.synthesize(
                text: "Hello", speaker: "test-speaker", language: "en",
                credentials: credentials, session: session
            ) { _ in }
        }
    }

    @Test func completedSynthesisDeliversPCM() async throws {
        let session = session("{\"code\":0,\"data\":\"AQIDBA==\"}\n{\"code\":20000000}\n")
        defer { session.invalidateAndCancel() }
        let received = OSAllocatedUnfairLock(initialState: Data())
        try await DoubaoVoiceServices.synthesize(
            text: "Hello", speaker: "test-speaker", language: "en",
            credentials: credentials, session: session
        ) { chunk in received.withLock { $0.append(chunk) } }
        #expect(received.withLock { $0 } == Data([1, 2, 3, 4]))
    }

    @Test func completionCanCarryTheFinalPCM() async throws {
        let session = session(#"{"code":20000000,"data":"AQIDBA=="}"#)
        defer { session.invalidateAndCancel() }
        let received = OSAllocatedUnfairLock(initialState: Data())
        try await DoubaoVoiceServices.synthesize(
            text: "Hello", speaker: "test-speaker", language: "en",
            credentials: credentials, session: session
        ) { chunk in received.withLock { $0.append(chunk) } }
        #expect(received.withLock { $0 } == Data([1, 2, 3, 4]))
    }

    @Test func httpSynthesisFailureIsReported() async {
        let session = session("upstream unavailable", status: 503)
        defer { session.invalidateAndCancel() }
        await #expect(throws: DoubaoVoiceServices.ServiceError.self) {
            try await DoubaoVoiceServices.synthesize(
                text: "Hello", speaker: "test-speaker", language: "en",
                credentials: credentials, session: session
            ) { _ in }
        }
    }

    @Test(arguments: ["", "not JSON", "{}", #"{"BaseResp":{}}"#])
    func malformedEnrollmentResponseFails(_ body: String) async {
        let session = session(body)
        defer { session.invalidateAndCancel() }
        await #expect(throws: DoubaoVoiceServices.ServiceError.self) {
            try await DoubaoVoiceServices.uploadSample(
                Data([1, 2]), format: "wav", speakerID: "S_test",
                credentials: credentials, session: session
            )
        }
    }

    @Test func validEnrollmentResponseSucceeds() async throws {
        let session = session(#"{"BaseResp":{"StatusCode":0}}"#)
        defer { session.invalidateAndCancel() }
        try await DoubaoVoiceServices.uploadSample(
            Data([1, 2]), format: "wav", speakerID: "S_test",
            credentials: credentials, session: session
        )
    }
}

struct AgentChatHTTPTests {
    private let credentials = CredentialStore.AgentCredentials(apiKey: "test-key", model: "test-model")

    private func session(_ body: String, status: Int = 200) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SpeechResponseProtocol.self]
        config.httpAdditionalHeaders = [
            "X-Test-Body": Data(body.utf8).base64EncodedString(),
            "X-Test-Status": String(status),
        ]
        return URLSession(configuration: config)
    }

    @Test func aChatResponsePassesThroughTheProductionHTTPClient() async throws {
        let session = session(#"{"choices":[{"message":{"content":"Hello"}}]}"#)
        defer { session.invalidateAndCancel() }
        let reply = try await ChatCompletionClient.complete(
            [.init(role: .user, content: "Hi")], credentials: credentials, session: session
        )
        #expect(reply == "Hello")
    }

    @Test(arguments: [
        "not JSON", #"{"choices":[]}"#, #"{"error":{"message":"quota"}}"#,
        #"{"choices":[{"message":{"content":"   "}}]}"#,
    ])
    func malformedOrEmptyChatCannotBeMistakenForASpokenReply(_ body: String) async {
        let session = session(body)
        defer { session.invalidateAndCancel() }
        await #expect(throws: ChatCompletionClient.ServiceError.self) {
            try await ChatCompletionClient.complete(
                [.init(role: .user, content: "Hi")], credentials: credentials, session: session
            )
        }
    }

    @Test func aNonSuccessHTTPChatResponseIsReported() async {
        let session = session("unavailable", status: 503)
        defer { session.invalidateAndCancel() }
        await #expect(throws: ChatCompletionClient.ServiceError.self) {
            try await ChatCompletionClient.complete(
                [.init(role: .user, content: "Hi")], credentials: credentials, session: session
            )
        }
    }
}

struct AgentServiceParsingTests {
    @Test func sessionsSavedBeforeTheAgentStillLoad() throws {
        let old = #"{"direction":"local","startedAt":0,"transcript":"你好","translation":"Hello"}"#
        let turn = try JSONDecoder().decode(SessionRecord.Turn.self, from: Data(old.utf8))
        #expect(turn.isAgent == false)
        var agentTurn = turn
        agentTurn.isAgent = true
        let round = try JSONDecoder().decode(
            SessionRecord.Turn.self, from: JSONEncoder().encode(agentTurn))
        #expect(round.isAgent)
    }


    @Test func chatReplyContentIsExtracted() throws {
        let body = #"{"choices":[{"message":{"role":"assistant","content":"{\"say\":\"Hi\"}"}}]}"#
        #expect(try ChatCompletionClient.parseReply(Data(body.utf8)) == #"{"say":"Hi"}"#)
    }

    @Test func chatErrorsAreReported() {
        let body = #"{"error":{"message":"bad key"}}"#
        #expect(throws: ChatCompletionClient.ServiceError(message: "bad key")) {
            try ChatCompletionClient.parseReply(Data(body.utf8))
        }
    }

    @Test func synthesisLinesDecodeAudioEndAndErrors() {
        let audio = Data([1, 2, 3, 4])
        #expect(DoubaoVoiceServices.parseSynthesisLine(
            #"{"code":0,"data":"\#(audio.base64EncodedString())"}"#) == .audio(audio))
        #expect(DoubaoVoiceServices.parseSynthesisLine(#"{"code":20000000,"data":null}"#) == .done)
        #expect(DoubaoVoiceServices.parseSynthesisLine(#"{"code":45000000,"message":"quota"}"#)
                == .failed("45000000: quota"))
        #expect(DoubaoVoiceServices.parseSynthesisLine("") == .ignored)
    }

    @Test func clonedVoicesNameTheirModel() {
        let cloned = DoubaoVoiceServices.synthesisBody(text: "Hi", speaker: "S_1", language: nil)
        let preset = DoubaoVoiceServices.synthesisBody(text: "Hi", speaker: "zh_female_x", language: nil)
        #expect((cloned["req_params"] as? [String: Any])?["model"] as? String
                == DoubaoVoiceServices.cloneModel)
        #expect((preset["req_params"] as? [String: Any])?["model"] == nil)
    }

    @Test func sampleTranscriptIsSentOnlyWhenGiven() {
        func sample(_ transcript: String) -> [String: Any]? {
            let body = DoubaoVoiceServices.uploadBody(Data([1]), format: "wav", speakerID: "S_1",
                                                     transcript: transcript, appID: "a")
            return (body["audios"] as? [[String: Any]])?.first
        }
        let english = DoubaoVoiceServices.uploadBody(Data([1]), format: "wav", speakerID: "S_1",
                                                    transcript: "", language: "en", appID: "a")
        #expect(english["language"] as? Int == 1)
        #expect(DoubaoVoiceServices.uploadBody(Data([1]), format: "wav", speakerID: "S_1",
                                               transcript: "", appID: "a")["language"] == nil)
        #expect(sample("  ")?["text"] == nil)
        #expect(sample("你好，今天天气不错")?["text"] as? String == "你好，今天天气不错")
    }

    @Test func synthesisAsksForPlayerReadyPCM() {
        let body = DoubaoVoiceServices.synthesisBody(text: "Hi", speaker: "S_1", language: "en")
        let params = body["req_params"] as? [String: Any]
        let audio = params?["audio_params"] as? [String: Any]
        #expect(params?["speaker"] as? String == "S_1")
        #expect(audio?["format"] as? String == "pcm")
        #expect(audio?["sample_rate"] as? Int == 24_000)
        #expect((params?["additions"] as? String)?.contains("\"explicit_language\":\"en\"") == true)
    }
}
