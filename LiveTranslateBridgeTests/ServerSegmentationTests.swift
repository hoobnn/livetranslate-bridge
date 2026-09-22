import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import LiveTranslateBridge

nonisolated private final class EventInbox: @unchecked Sendable {
    let values = Mutex<[TranslationClient.Event]>([])
}

@MainActor
private final class ServerFixture {
    let model = SubtitleModel()
    let client = TranslationClient(config: .init(apiKey: "fixture", workspaceID: "fixture", targetLanguage: "zh"))
    let events = EventInbox()

    init() {
        let events = events
        client.onEvent = { event in events.values.withLock { $0.append(event) } }
    }

    func send(_ frame: [String: Any], direction: SubtitleModel.Direction = .remote) throws {
        let json = try JSONSerialization.data(withJSONObject: frame)
        client.receiveFrameForTesting(String(decoding: json, as: UTF8.self))
        let batch = events.values.withLock { value in defer { value.removeAll() }; return value }
        for event in batch { model.ingestForTesting(event, from: direction) }
    }

    func source(_ id: String, _ text: String) throws {
        try send(["type": "conversation.item.input_audio_transcription.completed", "item_id": id, "transcript": text])
    }
    func link(_ output: String, _ source: String) throws {
        try send(["type": "conversation.item.created", "previous_item_id": source,
                  "item": ["id": output, "role": "assistant"]])
    }
    func translation(_ item: String, _ response: String, _ text: String) throws {
        try send(["type": "response.audio_transcript.done", "item_id": item, "response_id": response, "transcript": text])
    }
    func end(_ response: String, _ status: String) throws {
        try send(["type": "response.done", "response": ["id": response, "status": status, "output": []]])
    }
}

@MainActor
struct ServerSegmentationTests {
    @Test func cloneConfigurationMustBeConfirmedAtNestedOutput() throws {
        let client = TranslationClient(config: .init(apiKey: "fixture", workspaceID: "fixture",
            targetLanguage: "zh", wantsAudio: true, voice: .cloneEachReply))
        let inbox = EventInbox()
        client.onEvent = { event in inbox.values.withLock { $0.append(event) } }
        let frame: [String: Any] = ["type": "session.updated", "session": [
            "enable_voice_clone": true, "voice": "default", "voice_clone_options": ["frequency": "always"],
            "audio": ["output": ["voice": "Tina"]],
        ]]
        client.receiveFrameForTesting(String(decoding: try JSONSerialization.data(withJSONObject: frame), as: UTF8.self))
        let failed = inbox.values.withLock { $0.contains { if case .failed = $0.payload { true } else { false } } }
        let ready = inbox.values.withLock { $0.contains { if case .sessionReady = $0.payload { true } else { false } } }
        #expect(failed)
        #expect(!ready)
    }

    @Test func missingCloneIsReportedInsteadOfSilentVoiceFallback() throws {
        let client = TranslationClient(config: .init(apiKey: "fixture", workspaceID: "fixture",
            targetLanguage: "zh", wantsAudio: true, voice: .cloneEachReply))
        let inbox = EventInbox()
        client.onEvent = { event in inbox.values.withLock { $0.append(event) } }
        client.receiveFrameForTesting(#"{"type":"error","error":{"message":"cloned voice not found"}}"#)
        let failed = inbox.values.withLock { $0.contains { if case .failed = $0.payload { true } else { false } } }
        #expect(failed)
    }

    @Test(arguments: [false, true])
    func qwen38RecordedSessionKeepsFinalTailsAndOneCardPerSource(textOnly: Bool) throws {
        let f = ServerFixture()
        let frames = try JSONSerialization.jsonObject(with: Data(Qwen38RecordedFixture.json.utf8)) as! [[String: Any]]
        for var frame in frames {
            if textOnly, let type = frame["type"] as? String, type.hasPrefix("response.audio_transcript.") {
                frame["type"] = type.replacingOccurrences(of: "audio_transcript", with: "text")
                if let transcript = frame.removeValue(forKey: "transcript") { frame["text"] = transcript }
            }
            try f.send(frame)
        }
        #expect(f.model.entries.count == 2)
        #expect(f.model.entries.map(\.transcript) == ["Source sentence 1 with final tail.", "Source sentence 2 with final tail."])
        #expect(f.model.entries.map(\.translation) == ["完整译文1。", "完整译文2。"])
        #expect(f.model.entries.map(\.responseStatus) == ["completed", "completed"])
        let complete = f.model.entries.allSatisfy { $0.isComplete }
        #expect(complete)
    }

    @Test func assistantASRConversationChainDoesNotLinkSourcesAsTranslations() throws {
        let f = ServerFixture()
        for i in 0..<3 {
            let source = "source-\(i)", output = "output-\(i)", response = "response-\(i)"
            try f.send(["type": "input_audio_buffer.speech_started", "item_id": source])
            try f.link(output, source)
            try f.send(["type": "response.audio_transcript.delta", "item_id": output,
                        "response_id": response, "delta": "部分"])
            // Actual incident: ASR is also assistant, with the previous turn's
            // output as predecessor. This is ordering, not a translation link.
            try f.link(source, "output-\(i - 1)")
            try f.source(source, "source sentence \(i)")
            try f.send(["type": "input_audio_buffer.speech_stopped", "item_id": source])
            try f.translation(output, response, "完整译文 \(i)")
            try f.end(response, "completed")
        }
        f.model.ingestForTesting(.finished, from: .remote)
        #expect(f.model.entries.count == 3)
        #expect(f.model.entries.map(\.transcript) == (0..<3).map { "source sentence \($0)" })
        #expect(f.model.entries.map(\.translation) == (0..<3).map { "完整译文 \($0)" })
        #expect(f.model.entries.map(\.responseStatus) == ["completed", "completed", "completed"])
    }

    @Test func metadataBeforeASREvidenceStillCannotCreateFalseLink() throws {
        let f = ServerFixture()
        try f.source("earlier", "earlier source")
        try f.link("source", "earlier")
        try f.link("output", "source")
        try f.translation("output", "response", "完整译文")
        try f.source("source", "new source")
        #expect(f.model.entries.count == 2)
        #expect(f.model.entries.first { $0.transcript == "new source" }?.translation == "完整译文")
        #expect(f.model.entries.first { $0.transcript == "earlier source" }?.translation == "")
    }

    @Test func stopOnlyMarksUnfinishedTranslationAsInterrupted() throws {
        let f = ServerFixture()
        try f.source("source-only", "ASR only")
        try f.translation("finished-output", "finished-response", "完整译文")
        try f.send(["type": "response.audio_transcript.delta", "item_id": "partial-output",
                    "response_id": "partial-response", "delta": "部分译文"])
        f.model.ingestForTesting(.finished, from: .remote)
        #expect(f.model.entries.map(\.responseStatus) == [nil, nil, "interrupted"])
    }

    @Test func twoSentencesCanReturnInOppositeOrderWithoutMixing() throws {
        let f = ServerFixture()
        try f.source("a", "first sentence")
        try f.source("b", "second sentence")
        try f.link("out-a", "a"); try f.link("out-b", "b")
        try f.translation("out-b", "r-b", "第二句")
        try f.translation("out-a", "r-a", "第一句")
        #expect(f.model.entries.count == 2)
        #expect(f.model.entries[0].transcript == "first sentence")
        #expect(f.model.entries[0].translation == "第一句")
        #expect(f.model.entries[1].transcript == "second sentence")
        #expect(f.model.entries[1].translation == "第二句")
        let allComplete = f.model.entries.allSatisfy { $0.isComplete }
        #expect(allComplete)
    }

    @Test func lateSourceAndLateLinkMergeIntoOneCard() throws {
        let f = ServerFixture()
        try f.translation("out-a", "r-a", "第一句")
        try f.source("a", "first sentence")
        try f.link("out-a", "a")
        #expect(f.model.entries.count == 1)
        #expect(f.model.entries[0].transcript == "first sentence")
        #expect(f.model.entries[0].translation == "第一句")
        #expect(f.model.entries[0].isComplete)
    }

    @Test func emptyTextDoneStillEndsItsOwnTurn() throws {
        let f = ServerFixture()
        try f.source("a", "first")
        try f.link("out-a", "a")
        try f.send(["type": "response.audio_transcript.delta", "item_id": "out-a", "response_id": "r-a", "delta": "第一句"])
        try f.translation("out-a", "r-a", "")
        #expect(f.model.entries[0].translation == "第一句")
        #expect(f.model.entries[0].isComplete)
    }

    @Test func responseCancellationDoesNotSealTheNextSentence() throws {
        let f = ServerFixture()
        try f.source("a", "first"); try f.link("out-a", "a")
        try f.send(["type": "response.audio_transcript.delta", "item_id": "out-a", "response_id": "r-a", "delta": "第"])
        try f.source("b", "second"); try f.link("out-b", "b")
        try f.end("r-a", "cancelled")
        #expect(f.model.entries[0].responseStatus == "cancelled")
        #expect(f.model.entries[0].isComplete)
        #expect(!f.model.entries[1].isComplete)
        try f.translation("out-b", "r-b", "第二句")
        #expect(f.model.entries[1].translation == "第二句")
    }

    @Test func responseDoneCarriesFinalTextAndIncompleteStatus() throws {
        let f = ServerFixture()
        try f.source("a", "first"); try f.link("out-a", "a")
        try f.send(["type": "response.done", "response": ["id": "r-a", "status": "incomplete",
            "output": [["id": "out-a", "content": [["type": "audio", "transcript": "未完成译文"]]]]]])
        #expect(f.model.entries.count == 1)
        #expect(f.model.entries[0].translation == "未完成译文")
        #expect(f.model.entries[0].responseStatus == "incomplete")
    }

    @Test func duplicateEventIDsDoNotDuplicateDeltas() throws {
        let f = ServerFixture()
        let frame: [String: Any] = ["event_id": "event-one", "type": "conversation.item.input_audio_transcription.delta", "item_id": "a", "delta": "hello"]
        try f.send(frame); try f.send(frame)
        #expect(f.model.entries[0].transcript == "hello")
    }

    @Test func boundariesKeepServerAudioOffsets() throws {
        let f = ServerFixture()
        try f.send(["type": "input_audio_buffer.speech_started", "item_id": "a", "audio_start_ms": 123])
        try f.send(["type": "input_audio_buffer.speech_stopped", "item_id": "a", "audio_end_ms": 456])
        #expect(f.model.entries[0].speechStartMS == 123)
        #expect(f.model.entries[0].speechEndMS == 456)
        #expect(!f.model.entries[0].isComplete)
    }

    @Test func sameIDsAcrossDirectionsAndReconnectsAreSeparate() throws {
        let f = ServerFixture()
        try f.send(["type": "session.created", "session": ["id": "s1"]])
        try f.source("a", "remote")
        try f.send(["type": "conversation.item.input_audio_transcription.completed", "item_id": "a", "transcript": "local"], direction: .local)
        try f.send(["type": "session.created", "session": ["id": "s2"]])
        try f.source("a", "after reconnect")
        #expect(f.model.entries.map(\.transcript) == ["remote", "local", "after reconnect"])
    }

    @Test func longSessionsArchiveCorrelatedEntriesAndIgnoreLateFrames() throws {
        let f = ServerFixture()
        for i in 0..<600 {
            try f.source("s\(i)", "source \(i)")
            try f.link("o\(i)", "s\(i)")
            try f.translation("o\(i)", "r\(i)", "translation \(i)")
        }
        let count = f.model.entryCount
        try f.translation("o0", "r0", "late duplicate")
        #expect(f.model.entryCount == count)
        #expect(f.model.entries.count <= 500)
        #expect(f.model.transcriptText.contains("translation 0"))
    }
}

@Suite(.serialized)
struct ResponseAudioRoutingTests {
    @Test func cancellingAStartsBufferedBAndLateADoesNotTouchB() throws {
        let player = TranslationPlayer(manualRendering: true)
        try player.start(device: nil)
        defer { player.stop() }
        let router = ResponseAudioRouter(player: player)
        let a = TranslationClient.EventIdentity(streamID: "s", itemID: "oa", responseID: "a")
        let b = TranslationClient.EventIdentity(streamID: "s", itemID: "ob", responseID: "b")
        router.accept(a, event: .audio(Data(repeating: 0, count: 4800)))
        router.accept(b, event: .audio(Data(repeating: 0, count: 9600)))
        #expect(router.activeResponseForTesting == "s/a")
        #expect(router.pendingBytesForTesting == 9600)
        router.accept(a, event: .responseFinished("cancelled"))
        #expect(router.activeResponseForTesting == "s/b")
        #expect(abs(player.queuedTranslationSeconds - 0.2) < 0.001)
        router.accept(a, event: .audioComplete)
        router.accept(a, event: .audio(Data(repeating: 0, count: 4800)))
        #expect(abs(player.queuedTranslationSeconds - 0.2) < 0.001)
    }

    @Test func responseCreationOrderWinsOverAudioArrivalOrder() throws {
        let player = TranslationPlayer(manualRendering: true)
        try player.start(device: nil)
        defer { player.stop() }
        let router = ResponseAudioRouter(player: player)
        let a = TranslationClient.EventIdentity(streamID: "s", responseID: "a")
        let b = TranslationClient.EventIdentity(streamID: "s", responseID: "b")
        router.accept(a, event: .responseOpened)
        router.accept(b, event: .responseOpened)
        router.accept(b, event: .audio(Data(repeating: 0, count: 9600)))
        #expect(router.activeResponseForTesting == "s/a")
        #expect(player.queuedTranslationSeconds == 0)
        router.accept(a, event: .audio(Data(repeating: 0, count: 4800)))
        #expect(abs(player.queuedTranslationSeconds - 0.1) < 0.001)
        router.accept(a, event: .responseFinished("cancelled"))
        #expect(router.activeResponseForTesting == "s/b")
    }

    @Test func completedAudioDrainsBeforeNextResponsePlays() async throws {
        let player = TranslationPlayer(manualRendering: true)
        try player.start(device: nil)
        defer { player.stop() }
        let router = ResponseAudioRouter(player: player)
        let a = TranslationClient.EventIdentity(streamID: "s", responseID: "a")
        let b = TranslationClient.EventIdentity(streamID: "s", responseID: "b")
        router.accept(a, event: .audio(Data(repeating: 0, count: 4800)))
        router.accept(b, event: .audio(Data(repeating: 0, count: 9600)))
        router.accept(a, event: .audioComplete)
        #expect(router.activeResponseForTesting == "s/a")
        for _ in 0..<30 {
            _ = try player.renderOffline(frames: 1024)
            try await Task.sleep(for: .milliseconds(10))
            if router.activeResponseForTesting == "s/b" { break }
        }
        #expect(router.activeResponseForTesting == "s/b")
    }

    @Test func oversizedFirstChunkDoesNotBlockFollowingResponse() throws {
        let player = TranslationPlayer(manualRendering: true)
        try player.start(device: nil)
        defer { player.stop() }
        let router = ResponseAudioRouter(player: player)
        let a = TranslationClient.EventIdentity(streamID: "s", responseID: "a")
        let b = TranslationClient.EventIdentity(streamID: "s", responseID: "b")
        router.accept(a, event: .responseOpened)
        router.accept(b, event: .responseOpened)
        router.accept(b, event: .audio(Data(repeating: 0, count: 4800)))
        router.accept(a, event: .audio(Data(repeating: 0, count: 16 * 48_000)))
        #expect(router.activeResponseForTesting == "s/b")
        #expect(player.queuedTranslationSeconds > 0)
    }

    @Test func cancellingPendingResponseKeepsActiveAudio() throws {
        let player = TranslationPlayer(manualRendering: true)
        try player.start(device: nil)
        defer { player.stop() }
        let router = ResponseAudioRouter(player: player)
        let a = TranslationClient.EventIdentity(streamID: "s", responseID: "a")
        let b = TranslationClient.EventIdentity(streamID: "s", responseID: "b")
        router.accept(a, event: .audio(Data(repeating: 0, count: 4800)))
        router.accept(b, event: .audio(Data(repeating: 0, count: 9600)))
        router.accept(b, event: .responseFinished("incomplete"))
        #expect(router.activeResponseForTesting == "s/a")
        #expect(router.pendingBytesForTesting == 0)
        #expect(player.queuedTranslationSeconds > 0)
    }
}
