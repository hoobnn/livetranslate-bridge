import Foundation
import Testing
@testable import LiveTranslateBridge

private nonisolated final class RealtimeReceipts: @unchecked Sendable {
    private let lock = NSLock()
    private var wire: [(DoubaoRealtimeClient.JSONValue, TimeInterval)] = []
    private var events: [DoubaoRealtimeClient.Event] = []
    private var diagnostics: [DoubaoRealtimeClient.Event] = []
    func sent(_ value: DoubaoRealtimeClient.JSONValue) {
        lock.lock(); defer { lock.unlock() }
        wire.append((value, ProcessInfo.processInfo.systemUptime))
    }
    func received(_ event: DoubaoRealtimeClient.Event) {
        lock.lock(); defer { lock.unlock() }; events.append(event)
    }
    func diagnosed(_ event: DoubaoRealtimeClient.Event) {
        lock.lock(); defer { lock.unlock() }; diagnostics.append(event)
    }
    var messages: [(DoubaoRealtimeClient.JSONValue, TimeInterval)] {
        lock.lock(); defer { lock.unlock() }; return wire
    }
    var all: [DoubaoRealtimeClient.Event] {
        lock.lock(); defer { lock.unlock() }; return events
    }
    var observed: [DoubaoRealtimeClient.Event] {
        lock.lock(); defer { lock.unlock() }; return diagnostics
    }
}

@MainActor
struct DoubaoRealtimeClientTests {
    private func fixture(ready: Bool = true, handshakeTimeout: TimeInterval = 15) -> (DoubaoRealtimeClient, RealtimeReceipts) {
        let receipts = RealtimeReceipts()
        let client = DoubaoRealtimeClient(config: .init(apiKey: "fixture-key", instructions: "Answer briefly."),
                                          handshakeTimeoutForTesting: handshakeTimeout,
                                          sendForTesting: { receipts.sent($0) })
        client.onEvent = { receipts.received($0) }
        client.onDiagnosticEvent = { receipts.diagnosed($0) }
        client.connect(); client.flushForTesting()
        if ready { client.applyForTesting(#"{"type":"session.created","session":{"id":"session-1"}}"#) }
        return (client, receipts)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    @Test func creationUsesOnlyTheDocumentedRealtimeAudioContract() throws {
        let event = DoubaoRealtimeClient.createEvent(config: .init(apiKey: "secret", instructions: "Brief",
                                                                   sessionID: "resume-1"))
        #expect(event["type"]?.stringValue == "session.create")
        #expect(event["session"]?["model"]?.stringValue == "1.2.6.1")
        #expect(event["session"]?["id"]?.stringValue == "resume-1")
        #expect(event["session"]?["instructions"]?.stringValue == "Brief")
        #expect(event["session"]?["audio"]?["input"]?["format"]?["type"] == .string("pcm"))
        #expect(event["session"]?["audio"]?["input"]?["format"]?["rate"] == .number(16_000))
        #expect(event["session"]?["audio"]?["output"]?["format"]?["type"] == .string("pcm_s16le"))
        #expect(event["session"]?["audio"]?["output"]?["format"]?["rate"] == .number(24_000))
        #expect(event["session"]?["audio"]?["output"]?["voice"] == .string("zh_female_vv_jupiter_bigtts"))
        let encoded = try JSONEncoder().encode(event)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("secret"))
        #expect(try JSONDecoder().decode(DoubaoRealtimeClient.JSONValue.self, from: encoded) == event)
    }

    @Test func controlMessagesAndContextKeepTheirOfficialShapes() throws {
        let (client, receipts) = fixture()
        defer { client.abort() }
        client.setMuted(true); client.setMuted(false)
        client.updateInstructions("Updated brief")
        client.injectContext([.init(role: .user, text: "Three?", id: "u-1"),
                              .init(role: .assistant, text: "Four.", id: "a-1")])
        client.speak("Hello.")
        client.flushForTesting()
        let messages = receipts.messages.map(\.0)
        #expect(messages.map { $0["type"]?.stringValue } == [
            "session.create", "input_audio_mute.commit", "input_audio_unmute.commit",
            "session.update", "conversation.item.create", "speech_text_buffer.commit",
        ])
        #expect(messages[3]["session"]?["instructions"] == .string("Updated brief"))
        #expect(messages[3]["session"]?["id"] == .string("session-1"))
        guard case .array(let items) = messages[4]["items"] else { Issue.record("Missing context items"); return }
        #expect(items.count == 2)
        #expect(items[0]["id"] == .string("u-1"))
        #expect(items[0]["role"] == .string("user"))
        #expect(items[1]["role"] == .string("assistant"))
        #expect(items[1]["content"] == .array([.object(["type": .string("input_text"), "text": .string("Four.")])]))
        #expect(messages[5]["text"] == .string("Hello."))
    }

    @Test func realServerSnapshotsAndAnonymousAudioRetainTheirIdentity() throws {
        let (client, receipts) = fixture()
        defer { client.abort() }
        client.applyForTesting(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"q-1","delta":"hello"}"#)
        client.applyForTesting(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"q-1","delta":"Hello."}"#)
        client.applyForTesting(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"q-1","text":"Hello there."}"#)
        client.applyForTesting(#"{"type":"response.output_text.delta","response_id":"r-1","delta":"Good "}"#)
        client.applyForTesting(#"{"type":"response.output_text.done","response_id":"r-1","text":"Good morning."}"#)
        client.applyForTesting(#"{"type":"response.output_audio.started","response_id":"r-1","question_id":"q-1"}"#)
        client.applyForTesting(#"{"type":"response.output_audio.delta","delta":"AQACAA=="}"#)
        client.applyForTesting(#"{"type":"response.output_audio.done","response_id":"r-1"}"#)
        client.applyForTesting(#"{"type":"response.done","response":{"usage":{"total_tokens":3}}}"#)
        let source = receipts.all.filter { $0.kind == .sourceTranscript }
        #expect(source.map(\.text) == ["hello", "Hello.", "Hello there."])
        #expect(source.map(\.isFinal) == [false, false, true])
        #expect(source.allSatisfy { $0.itemID == "q-1" })
        let audio = try #require(receipts.all.first { $0.kind == .audio })
        #expect(audio.audio == Data([1, 0, 2, 0]))
        #expect(audio.responseID == "r-1")
        #expect(receipts.all.last?.kind == .responseDone)
        #expect(receipts.all.last?.responseID == "r-1")
        #expect(receipts.all.last?.payload["response"]?["usage"]?["total_tokens"] == .number(3))
    }

    @Test func canceledAudioStaysBlockedAfterUnmuteWhileANewResponseCanPlay() {
        let (client, receipts) = fixture()
        defer { client.abort() }
        client.applyForTesting(#"{"type":"response.output_audio.started","response_id":"old"}"#)
        client.cancelResponse(); client.setMuted(true); client.flushForTesting()
        client.applyForTesting(#"{"type":"response.output_audio.delta","delta":"AQACAA=="}"#)
        client.applyForTesting(#"{"type":"response.canceled"}"#)
        client.setMuted(false); client.appendAudio(Data(repeating: 0, count: 640)); client.flushForTesting()
        client.applyForTesting(#"{"type":"response.output_audio.delta","response_id":"old","delta":"AQACAA=="}"#)
        client.applyForTesting(#"{"type":"response.output_audio.started","response_id":"new"}"#)
        client.applyForTesting(#"{"type":"response.output_audio.delta","delta":"AwAEAA=="}"#)
        let audio = receipts.all.filter { $0.kind == .audio }
        #expect(audio.count == 1)
        #expect(audio.first?.responseID == "new")
        #expect(audio.first?.audio == Data([3, 0, 4, 0]))
        #expect(receipts.observed.filter { $0.kind == .audio }.count == 3)
        #expect(receipts.messages.filter { $0.0["type"] == .string("response.cancel") }.count == 1)
    }

    @Test func cancelWithNoActiveResponseDoesNotSendAnInvalidRemoteCancel() {
        let (client, receipts) = fixture()
        defer { client.abort() }
        client.cancelResponse(); client.flushForTesting()
        #expect(!receipts.messages.contains { $0.0["type"] == .string("response.cancel") })
        client.applyForTesting(#"{"type":"response.output_audio.delta","delta":"AQACAA=="}"#)
        #expect(!receipts.all.contains { $0.kind == .audio })
    }

    @Test func captureBlocksArePacedAndCommitPrecedesInputMuteWithoutMutingTheReply() async throws {
        let (client, receipts) = fixture()
        defer { client.abort() }
        client.appendAudio(Data(repeating: 0, count: 6_400))
        client.commitAudio(); client.setMuted(true)
        try await waitUntil { receipts.messages.last?.0["type"] == .string("input_audio_mute.commit") }
        let wire = receipts.messages
        let audio = wire.filter { $0.0["type"] == .string("input_audio_buffer.append") }
        #expect(audio.count == 10)
        #expect(audio.allSatisfy { Data(base64Encoded: $0.0["audio"]?.stringValue ?? "")?.count == 640 })
        #expect(try #require(audio.last?.1) - #require(audio.first?.1) >= 0.16)
        #expect(wire.suffix(2).map { $0.0["type"]?.stringValue } == ["input_audio_buffer.commit", "input_audio_mute.commit"])
        client.applyForTesting(#"{"type":"response.output_audio.started","response_id":"reply"}"#)
        client.applyForTesting(#"{"type":"response.output_audio.delta","delta":"AQACAA=="}"#)
        #expect(receipts.all.last?.kind == .audio)
    }

    @Test func inputMuteDropsCaptureThatWasNotCommitted() {
        let (client, receipts) = fixture()
        defer { client.abort() }
        client.appendAudio(Data(repeating: 0, count: 3_200)); client.setMuted(true); client.flushForTesting()
        client.setMuted(false); client.commitAudio(); client.flushForTesting()
        #expect(receipts.messages.filter { $0.0["type"] == .string("input_audio_buffer.append") }.count <= 1)
    }

    @Test func connectingTimesOutEvenWhenNoCallerWaitsForReadiness() async throws {
        let (client, receipts) = fixture(ready: false, handshakeTimeout: 0.01)
        try await waitUntil { receipts.all.last?.kind == .failed }
        #expect(receipts.all.last?.text?.contains("session.created") == true)
        client.applyForTesting(#"{"type":"session.created","session":{"id":"too-late"}}"#)
        #expect(await client.waitUntilReady(timeout: 0.01) == false)
        #expect(receipts.messages.count == 1)
    }

    @Test func callbacksCanDetachThemselvesWithoutDeadlockingTheTransport() {
        let (client, receipts) = fixture()
        defer { client.abort() }
        client.onEvent = { event in
            receipts.received(event)
            client.onEvent = nil
            client.onDiagnosticEvent = nil
        }
        client.applyForTesting(#"{"type":"session.updated"}"#)
        let count = receipts.all.count
        client.applyForTesting(#"{"type":"session.updated"}"#)
        #expect(receipts.all.count == count)
        #expect(client.onEvent == nil)
        #expect(client.onDiagnosticEvent == nil)
    }

    @Test func audioEncodingWorkDoesNotAccumulateIntoCadenceDrift() async throws {
        let receipts = RealtimeReceipts()
        let client = DoubaoRealtimeClient(config: .init(apiKey: "fixture", instructions: "Brief"),
                                          sendForTesting: { event in
            receipts.sent(event)
            // Reproduce transport/encoding work after each packet. A relative
            // 20 ms delay adds this cost on every frame and falls behind input.
            if event["type"] == .string("input_audio_buffer.append") { Thread.sleep(forTimeInterval: 0.008) }
        })
        defer { client.abort() }
        client.connect(); client.flushForTesting()
        client.applyForTesting(#"{"type":"session.created","session":{"id":"paced"}}"#)
        client.appendAudio(Data(repeating: 0, count: 25_600)); client.commitAudio()
        try await waitUntil { receipts.messages.last?.0["type"] == .string("input_audio_buffer.commit") }
        let packets = receipts.messages.filter { $0.0["type"] == .string("input_audio_buffer.append") }
        #expect(packets.count == 40)
        let elapsed = try #require(packets.last?.1) - #require(packets.first?.1)
        #expect(elapsed >= 0.74) // No burst transmission of the 800 ms query.
        #expect(elapsed < 0.95) // 39 * (20 + 8) ms would exceed 1.09 seconds.
    }

    @Test func malformedAudioAndServiceErrorsFailExplicitlyAndRedactTheKey() {
        let (client, receipts) = fixture()
        client.applyForTesting(#"{"type":"error","event_id":"bad-1","error":{"message":"invalid fixture-key"}}"#)
        #expect(receipts.all.last?.kind == .failed)
        #expect(receipts.all.last?.text == "invalid [redacted]")
        #expect(receipts.all.last?.eventID == "bad-1")
        #expect(throws: (any Error).self) {
            try DoubaoRealtimeClient.decodeEvent(Data(#"{"type":"response.output_audio.delta","delta":"AQ=="}"#.utf8))
        }
        #expect(throws: (any Error).self) { try DoubaoRealtimeClient.decodeEvent(Data("[]".utf8)) }
    }

    @Test func readinessTimeoutAndOversizedBacklogRetireTheSession() async {
        let (connecting, receipts) = fixture(ready: false)
        #expect(await connecting.waitUntilReady(timeout: 0.01) == false)
        #expect(receipts.all.last?.kind == .failed)
        connecting.applyForTesting(#"{"type":"session.created","session":{"id":"late"}}"#)
        #expect(await connecting.waitUntilReady(timeout: 0.01) == false)
        let (client, backlog) = fixture()
        client.appendAudio(Data(repeating: 0, count: 64_002)); client.flushForTesting()
        #expect(backlog.all.last?.kind == .failed)
        #expect(backlog.all.last?.text?.contains("backlog") == true)
    }

    @Test func closeRequiresTheServerAckAndRejectsLateAudio() async throws {
        let (client, receipts) = fixture()
        let closing = Task { await client.close(timeout: 10) }
        try await waitUntil { receipts.messages.last?.0["type"] == .string("session.close") }
        client.applyForTesting(#"{"type":"response.output_audio.delta","delta":"AQACAA=="}"#)
        client.applyForTesting(#"{"type":"session.closed"}"#)
        #expect(await closing.value)
        client.applyForTesting(#"{"type":"response.output_audio.delta","delta":"AQACAA=="}"#)
        #expect(!receipts.all.contains { $0.kind == .audio })
        #expect(receipts.all.last?.kind == .closed)
        #expect(await client.waitUntilReady(timeout: 0.01) == false)
        let (unacknowledged, failures) = fixture()
        #expect(await unacknowledged.close(timeout: 0.01) == false)
        #expect(failures.all.last?.kind == .failed)
    }
}
