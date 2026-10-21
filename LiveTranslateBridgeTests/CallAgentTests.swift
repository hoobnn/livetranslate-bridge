//
//  CallAgentTests.swift
//  LiveTranslateBridgeTests
//

import Foundation
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
