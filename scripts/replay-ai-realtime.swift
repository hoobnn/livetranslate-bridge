import Foundation
import os

/// Production CallAgent + real Doubao WebSocket, with a file sink only.
/// This executable never creates a player or an audio device.
private nonisolated final class RealtimeTrace: @unchecked Sendable {
    private let lock = NSLock()
    private let output: URL
    private let key: String
    private let started = Date()
    private var eventCounts: [String: Int] = [:]
    private var responses: [String] = []
    private var failures: [String] = []
    private var delivered = Data()
    private var audio: [String: Data] = [:]

    init(output: URL, key: String) { self.output = output; self.key = key }

    func observe(_ event: DoubaoRealtimeClient.Event) {
        lock.lock(); defer { lock.unlock() }
        let kind = event.kind.rawValue
        let encoded = try? JSONEncoder().encode(event.payload)
        let payload = encoded.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let wireType = payload["type"] as? String ?? kind
        eventCounts[wireType, default: 0] += 1
        var row: [String: Any] = ["type": wireType, "kind": kind,
            "receipt_seconds": Date().timeIntervalSince(started), "is_final": event.isFinal]
        row["response_id"] = event.responseID
        row["item_id"] = event.itemID
        row["session_id"] = event.sessionID
        if let text = event.text { row["text"] = text.replacingOccurrences(of: key, with: "[redacted]") }
        if let pcm = event.audio {
            row["audio_bytes"] = pcm.count
            audio[event.responseID ?? "unknown", default: Data()].append(pcm)
        }
        if event.kind == .responseText, event.isFinal, let text = event.text { responses.append(text) }
        if event.kind == .failed { failures.append(event.text ?? "Realtime service failed") }
        do {
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            let file = output.appending(path: "events.jsonl")
            if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd(); try handle.write(contentsOf: data + Data([10])); try handle.close()
        } catch { failures.append(error.localizedDescription) }
    }

    func accept(_ pcm: Data) { lock.lock(); delivered.append(pcm); lock.unlock() }
    func count(_ type: String) -> Int { lock.lock(); defer { lock.unlock() }; return eventCounts[type, default: 0] }
    var deliveredBytes: Int { lock.lock(); defer { lock.unlock() }; return delivered.count }
    var finalReplies: [String] { lock.lock(); defer { lock.unlock() }; return responses }
    var errors: [String] { lock.lock(); defer { lock.unlock() }; return failures }

    func save() throws {
        lock.lock(); defer { lock.unlock() }
        try delivered.write(to: output.appending(path: "delivered.pcm"))
        for (id, pcm) in audio {
            let safeID = id.filter { $0.isLetter || $0.isNumber || $0 == "-" }
            try pcm.write(to: output.appending(path: "response-\(safeID).pcm"))
        }
    }
}

private nonisolated struct ReplayFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@main struct ReplayAIRealtime {
    @MainActor static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }

    @MainActor private static func wait(
        _ message: String, seconds: Double = 30,
        trace: RealtimeTrace, until condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(Int(seconds * 1_000))
        while !condition(), clock.now < deadline {
            if let error = trace.errors.first { throw ReplayFailure(message: error) }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard condition() else { throw ReplayFailure(message: "Timed out: \(message)") }
    }

    @MainActor static func send(_ path: String, into agent: CallAgent) async throws {
        let pcm = try Data(contentsOf: URL(fileURLWithPath: path))
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2), pcm.count <= 960_000 else {
            throw ReplayFailure(message: "Input must be 16 kHz mono Int16 PCM, 0–30 seconds")
        }
        let input = pcm + Data(repeating: 0, count: 16_000)
        let clock = ContinuousClock()
        let began = clock.now
        for offset in stride(from: 0, to: input.count, by: 640) {
            agent.appendRemoteAudio(input.subdata(in: offset..<min(offset + 640, input.count)))
            try await clock.sleep(until: began + .milliseconds((offset / 640 + 1) * 20))
        }
    }

    @MainActor static func run() async throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { throw ReplayFailure(message: "usage: replay-ai-realtime caller-one.pcm caller-two.pcm new-output-directory") }
        let output = URL(fileURLWithPath: args[3], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw ReplayFailure(message: "Output directory already exists") }
        let speech = CredentialStore.loadDoubao()
        guard speech.isComplete, speech.appID.isEmpty else { throw ReplayFailure(message: "Configure a Doubao Speech API Key in the app or DOUBAO_API_KEY") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let trace = RealtimeTrace(output: output, key: speech.accessToken)
        let clients = OSAllocatedUnfairLock<[DoubaoRealtimeClient]>(initialState: [])
        let agent = CallAgent(services: .init(makeRealtime: { config in
            let real = DoubaoRealtimeClient(config: config)
            real.onDiagnosticEvent = { trace.observe($0) }
            clients.withLock { $0.append(real) }
            return real
        }))
        agent.onAudio = { trace.accept($0) }
        agent.begin(.init(
            materials: "Order A123 was originally scheduled for tomorrow at 3 PM. The customer and operator may agree a new delivery time. The latest agreement in the conversation takes priority over the original booking.",
            goal: "Confirm delivery time in one short English sentence per answer. Follow the latest manual agreement. Do not invent facts.",
            theirLanguage: "en", myLanguage: "zh", chat: .init(), speech: speech,
            speakerID: speech.agentSpeakerID, backend: .doubaoRealtime,
            realtimeVoice: DoubaoRealtimeClient.defaultVoice
        ))
        var summary: [String: Any] = ["model": "1.2.6.1", "backend": "doubaoRealtime", "playback": false]
        do {
            try await wait("realtime client construction", seconds: 15, trace: trace) { clients.withLock { !$0.isEmpty } }
            var real = try { () throws -> DoubaoRealtimeClient in
                guard let client = clients.withLock({ $0.last }) else { throw ReplayFailure(message: "Agent did not create realtime client") }; return client
            }()
            guard await real.waitUntilReady(timeout: 15) else { throw ReplayFailure(message: trace.errors.first ?? "Session did not become ready") }
            try await wait("initial input readiness", seconds: 10, trace: trace) { !agent.isRealtimeConnecting }
            try await send(args[1], into: agent)
            real.commitAudio(); real.setMuted(true)
            try await wait("first complete response", trace: trace) { trace.count("response.done") >= 1 }
            let first = trace.finalReplies.last ?? ""
            guard first.lowercased().range(of: "\\b(three|3)\\b", options: .regularExpression) != nil else { throw ReplayFailure(message: "First answer did not confirm the original time: \(first)") }
            summary["first_reply"] = first

            agent.takeOver()
            guard agent.phase == .handedOver else { throw ReplayFailure(message: "Takeover did not become active") }
            agent.noteRemote("Can we move delivery to four tomorrow afternoon?")
            agent.noteLocal("Yes. Order A123 is now confirmed for four tomorrow afternoon.")
            let contexts = trace.count("conversation.item.added")
            let previousClient = real
            let clientCount = clients.withLock { $0.count }
            agent.handBack()
            try await wait("fresh session after manual handback", seconds: 15, trace: trace) {
                clients.withLock { $0.count > clientCount }
            }
            guard let nextClient = clients.withLock({ $0.last }), nextClient !== previousClient else {
                throw ReplayFailure(message: "Manual handback did not replace the realtime session")
            }
            real = nextClient
            guard await real.waitUntilReady(timeout: 15) else { throw ReplayFailure(message: "Replacement session did not become ready") }
            try await wait("manual context acknowledgement and input readiness", seconds: 10, trace: trace) {
                !agent.isRealtimeConnecting && trace.count("conversation.item.added") > contexts
            }
            try await send(args[2], into: agent)
            real.commitAudio(); real.setMuted(true)
            try await wait("second complete response", trace: trace) { trace.count("response.done") >= 2 }
            let second = trace.finalReplies.last ?? ""
            guard second.lowercased().range(of: "\\b(four|4)\\b", options: .regularExpression) != nil else { throw ReplayFailure(message: "Manual change was not retained: \(second)") }
            summary["second_reply"] = second
            summary["manual_change_retained"] = true
            summary["handback_uses_fresh_session"] = true

            let before = trace.deliveredBytes
            real.speak("I am checking all the delivery details now. Please hold for a moment while I confirm the updated address and delivery time for your order.")
            try await wait("interruptible audio", trace: trace) { trace.deliveredBytes > before }
            let cancellations = trace.count("response.canceled")
            agent.takeOver()
            let stoppedBytes = trace.deliveredBytes
            try await wait("server interruption acknowledgement", seconds: 8, trace: trace) { trace.count("response.canceled") > cancellations }
            try await Task.sleep(for: .milliseconds(300))
            guard trace.deliveredBytes == stoppedBytes else { throw ReplayFailure(message: "Late audio was delivered after takeover") }
            summary["takeover_stops_late_audio"] = true
            summary["session_closed_ack"] = await real.close(timeout: 5)
            guard summary["session_closed_ack"] as? Bool == true else { throw ReplayFailure(message: "Service did not acknowledge close") }
            guard trace.errors.isEmpty else { throw ReplayFailure(message: trace.errors.joined(separator: "; ")) }
            summary["passed"] = true
        } catch {
            summary["passed"] = false
            summary["error"] = error.localizedDescription.replacingOccurrences(of: speech.accessToken, with: "[redacted]")
            clients.withLock { $0 }.forEach { $0.abort() }
        }
        agent.end()
        try trace.save()
        summary["delivered_audio_bytes"] = trace.deliveredBytes
        summary["session_count"] = clients.withLock { $0.count }
        summary["replies"] = trace.finalReplies
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: output.appending(path: "summary.json"))
        print(String(decoding: data, as: UTF8.self))
        guard summary["passed"] as? Bool == true else { throw ReplayFailure(message: "Realtime AI call did not pass; see saved summary and events") }
    }
}
