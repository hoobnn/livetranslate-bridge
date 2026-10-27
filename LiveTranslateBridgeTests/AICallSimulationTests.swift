import AVFoundation
import Foundation
import os
import Testing
@testable import LiveTranslateBridge

/// Runs the real board, agent and offline audio route. Chat and synthesis
/// are local fixtures; no credentials, network or hardware audio are used.
private nonisolated struct SimulatedTurn: Sendable {
    var say: String
    var gloss: String
    var hangsUp: Bool
}

private actor SimulatedCallServices {
    private(set) var requests: [[ChatCompletionClient.Message]] = []
    private(set) var speakers: [String] = []
    private var turns: [SimulatedTurn]

    init(_ turns: [SimulatedTurn]) { self.turns = turns }

    func complete(_ messages: [ChatCompletionClient.Message]) throws -> String {
        requests.append(messages)
        guard !turns.isEmpty else { throw SimulationError.unexpectedReply }
        let turn = turns.removeFirst()
        let data = try JSONSerialization.data(withJSONObject: [
            "say": turn.say, "gloss": turn.gloss, "hang_up": turn.hangsUp,
        ])
        return String(decoding: data, as: UTF8.self)
    }

    func synthesize(speaker: String, onAudio: @Sendable (Data) -> Void) {
        speakers.append(speaker)
        // Half a second of 24 kHz signed Int16, rendered offline below.
        let samples: [Int16] = (0..<12_000).map {
            Int16(sin(Double($0) * 2 * .pi * 440 / 24_000) * 3_000)
        }
        onAudio(samples.withUnsafeBytes { Data($0) })
    }

    enum SimulationError: Error { case unexpectedReply }
}

@MainActor
struct AICallSimulationTests {
    private let chat = CredentialStore.AgentCredentials(apiKey: "fixture", model: "fixture")

    private func services(_ fixture: SimulatedCallServices) -> CallAgent.Services {
        .init(complete: { messages, _ in try await fixture.complete(messages) },
              synthesize: { _, speaker, _, _, onAudio in
                  await fixture.synthesize(speaker: speaker, onAudio: onAudio)
              })
    }

    private func model(services: CallAgent.Services? = nil, muted: Bool = false) -> SubtitleModel {
        var result: SubtitleModel!
        SubtitleModel.withTemporaryDefaults {
            let agent = CallAgent(services: services ?? .init())
            agent.replyDelay = .zero
            result = SubtitleModel(agent: agent)
            result.agentEnabled = true
            result.agentBackend = .chatAndTTS
            result.provider = .doubao
            result.agentGoal = "确认订单 A123 明天下午三点送达"
            result.agentMaterials = "订单号 A123，明天下午三点送达；用户后来可改为四点。"
            result.localTranslationVolume = muted ? 0 : 1
            result.beginForTesting()
        }
        return result
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }

    @Test func anUnconfiguredVoiceUsesTheDefaultAndStartsListening() async throws {
        let model = model()
        defer { model.stop() }
        await model.beginAgentForTesting(chat: chat, speech: .init(appID: "", accessToken: "fixture"))
        #expect(model.agent.phase == .listening)
        #expect(model.agent.configForTesting?.speakerID == DoubaoTranslationClient.defaultSpeakerID)
    }

    @Test func simulatedCallerGetsAudioAndTheUserCanTakeOverAndHandBack() async throws {
        let fixture = SimulatedCallServices([
            .init(say: "It arrives tomorrow at three.", gloss: "明天下午三点送达。", hangsUp: false),
            .init(say: "Yes, four is now confirmed. Goodbye.", gloss: "好的，已确认改为四点。再见。", hangsUp: true),
        ])
        let model = model(services: services(fixture))
        let player = TranslationPlayer(manualRendering: true)
        let queued = OSAllocatedUnfairLock(initialState: 0)
        player.onTranslationQueued = { data in queued.withLock { $0 += data.count } }
        try player.start(device: nil)
        defer { model.stop(); player.stop() }
        await model.beginAgentForTesting(chat: chat, speech: .init(appID: "", accessToken: "fixture"), player: player)
        try #require(model.agent.phase == .listening)

        model.ingestForTesting(.speechStarted, from: .remote)
        model.ingestForTesting(.transcriptComplete("When will order A123 arrive?"), from: .remote)
        model.ingestForTesting(.translationComplete("订单 A123 什么时候到？"), from: .remote)
        try await waitUntil { model.entries.filter(\.isAgent).count == 1 && model.agent.phase == .listening }
        #expect(queued.withLock { $0 } == 24_000)
        let entry = model.entries.last { $0.isAgent }
        let first = try #require(entry)
        #expect(first.translation == "It arrives tomorrow at three.")
        #expect(first.transcript == "明天下午三点送达。")
        #expect(first.isComplete)
        var peak: Float = 0
        for _ in 0..<20 {
            let buffer = try player.renderOffline(frames: 1024)
            for index in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(buffer.floatChannelData![0][index]))
            }
        }
        #expect(peak > 0.01)

        model.ingestForTesting(.speechStarted, from: .local)
        #expect(model.agent.phase == .handedOver)
        #expect(player.queuedTranslationSeconds == 0)
        let localID = TranslationClient.EventIdentity(streamID: "simulation", itemID: "local-1")
        model.ingestForTesting(.identified(localID, .transcriptComplete("改成四点吧。")), from: .local)
        model.ingestForTesting(.identified(localID, .translationComplete("Four would be better.")), from: .local)
        model.ingestForTesting(.transcriptComplete("Is four now confirmed?"), from: .remote)
        model.ingestForTesting(.translationComplete("已经确认四点了吗？"), from: .remote)
        #expect(model.entries.filter(\.isAgent).count == 1)
        #expect(model.agent.phase == .handedOver)

        model.agent.handBack()
        try await waitUntil { model.entries.filter(\.isAgent).count == 2 && model.agent.phase == .handedOver }
        let requests = await fixture.requests
        #expect(requests.count == 2)
        #expect(requests.last?.contains(where: { $0.role == .assistant && $0.content == "Four would be better." }) == true)
        #expect(requests.last?.last?.content == "Is four now confirmed?")
        #expect(await fixture.speakers == [DoubaoTranslationClient.defaultSpeakerID, DoubaoTranslationClient.defaultSpeakerID])
        #expect(queued.withLock { $0 } == 48_000)
    }

    @Test func configuredPresetAndTrainedVoiceArePreserved() async throws {
        for voice in ["zh_female_vv_uranus_bigtts", "S_fixture"] {
            let model = model()
            let speech = CredentialStore.DoubaoCredentials(
                appID: "", accessToken: "fixture", speakerID: "zh_female_vv_uranus_bigtts",
                cloneSpeakerID: voice.hasPrefix("S_") ? voice : ""
            )
            await model.beginAgentForTesting(chat: chat, speech: speech)
            #expect(model.agent.phase == .listening)
            #expect(model.agent.configForTesting?.speakerID == voice)
            model.stop()
        }
    }

    @Test func missingChatAndMutedOutputDoNotStartAutomaticReplies() async {
        let speech = CredentialStore.DoubaoCredentials(appID: "", accessToken: "fixture")
        let missingChat = model()
        await missingChat.beginAgentForTesting(chat: .init(), speech: speech)
        #expect(missingChat.agent.phase == .off)
        #expect(missingChat.audioNotice != nil)
        missingChat.stop()

        let muted = model(muted: true)
        await muted.beginAgentForTesting(chat: chat, speech: speech)
        #expect(muted.agent.phase == .off)
        #expect(muted.audioNotice != nil)
        muted.stop()
    }
}
