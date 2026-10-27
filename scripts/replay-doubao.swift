import Foundation

/// Replays a file through the app's production Doubao client. No audio device
/// or player is created: returned PCM is written to a file only.
private final class ReplayTrace: @unchecked Sendable {
    private let lock = NSLock()
    private let trace: FileHandle
    private let audio: FileHandle
    private let started = Date()
    private let token: String
    private var ready = false
    private var finished = false
    private var failures: [String] = []
    private var transcripts = 0
    private var translations = 0
    private var audioBytes = 0
    private var writeError: String?

    init(path: String, token: String) throws {
        self.token = token
        let manager = FileManager.default
        for output in [path, path + ".pcm"] {
            guard !manager.fileExists(atPath: output) else {
                throw ReplayError(message: "Output already exists: \(output)")
            }
        }
        guard manager.createFile(atPath: path, contents: nil),
              manager.createFile(atPath: path + ".pcm", contents: nil) else {
            throw ReplayError(message: "Cannot create output files")
        }
        trace = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        audio = try FileHandle(forWritingTo: URL(fileURLWithPath: path + ".pcm"))
    }

    func append(_ event: TranslationClient.Event) {
        lock.lock()
        defer { lock.unlock() }
        var row: [String: Any] = ["receipt_seconds": Date().timeIntervalSince(started)]
        if case .identified(let identity, _) = event {
            row["stream_id"] = identity.streamID
            row["item_id"] = identity.itemID
            row["audio_ms"] = identity.audioMS
        }
        switch event.payload {
        case .sessionReady: row["type"] = "sessionReady"; ready = true
        case .streamStarted(let id): row["type"] = "streamStarted"; row["stream_id"] = id
        case .finished: row["type"] = "finished"; finished = true
        case .failed(let message):
            let safe = token.isEmpty ? message : message.replacingOccurrences(of: token, with: "[redacted]")
            row["type"] = "failed"; row["message"] = safe; failures.append(safe)
        case .transcript(let text): row["type"] = "transcript"; row["text"] = text
        case .transcriptComplete(let text):
            row["type"] = "transcriptComplete"; row["text"] = text
            if !text.isEmpty { transcripts += 1 }
        case .translation(let text): row["type"] = "translation"; row["text"] = text
        case .translationComplete(let text):
            row["type"] = "translationComplete"; row["text"] = text
            if !text.isEmpty { translations += 1 }
        case .audio(let data):
            row["type"] = "audio"; row["bytes"] = data.count; audioBytes += data.count
            do { try audio.write(contentsOf: data) } catch { writeError = error.localizedDescription }
        case .audioComplete: row["type"] = "audioComplete"
        case .speechStarted: row["type"] = "speechStarted"
        case .speechStopped: row["type"] = "speechStopped"
        case .responseFinished(let status): row["type"] = "responseFinished"; row["status"] = status
        default: row["type"] = String(describing: event.payload)
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            try trace.write(contentsOf: data + Data([10]))
        } catch { writeError = error.localizedDescription }
    }

    func complete(mode: String, seconds: Double) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        try trace.synchronize()
        try audio.synchronize()
        let passed = ready && finished && failures.isEmpty && writeError == nil && transcripts > 0
            && (mode == "transcript" ? translations == 0 : translations > 0)
            && (mode == "audio" ? audioBytes > 0 : audioBytes == 0)
        return ["passed": passed, "session_ready": ready, "session_finished": finished,
                "mode": mode, "input_seconds": seconds,
                "transcripts": transcripts, "translations": translations,
                "audio_bytes": audioBytes, "audio_seconds": Double(audioBytes) / 48_000,
                "failures": failures, "write_error": writeError ?? ""]
    }
}

private struct ReplayError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@main struct ReplayDoubao {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    static func run() async throws {
        let args = CommandLine.arguments
        guard (3...7).contains(args.count) else {
            throw ReplayError(message: "usage: replay-doubao input.pcm output.jsonl [text|audio|transcript] [source] [target] [preset|clone]")
        }
        let mode = args.count > 3 ? args[3] : "text"
        let source = args.count > 4 ? args[4] : "en"
        let target = args.count > 5 ? args[5] : "zh"
        let voice = args.count > 6 ? args[6] : "preset"
        guard ["text", "audio", "transcript"].contains(mode), ["preset", "clone"].contains(voice),
              TranslationProvider.doubao.supports(source),
              mode == "transcript" || (source != target && TranslationProvider.doubao.supports(target)
                && TranslationProvider.doubao.supportsPair(source, target)) else {
            throw ReplayError(message: "Invalid mode, voice or language pair")
        }
        let credentials = CredentialStore.loadDoubao()
        guard credentials.isComplete else {
            throw ReplayError(message: "Doubao credentials unavailable; configure the app or DOUBAO_API_KEY / DOUBAO_APP_ID + DOUBAO_ACCESS_TOKEN")
        }
        let pcm = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2), pcm.count <= 960_000 else {
            throw ReplayError(message: "Input must be 16 kHz mono Int16 PCM, 0–30 seconds")
        }
        let log = try ReplayTrace(path: args[2], token: credentials.accessToken)
        let client = DoubaoTranslationClient(config: .init(
            appID: credentials.appID, accessToken: credentials.accessToken,
            sourceLanguage: source, targetLanguage: mode == "transcript" ? nil : target,
            wantsAudio: mode == "audio", voice: voice == "clone" ? .cloneOnce : .preset,
            presetSpeakerID: credentials.speakerID
        ), diagnosticLabel: "doubao-file-replay")
        client.onEvent = { log.append($0) }
        client.connect()
        if await client.waitUntilReady(timeout: 15) {
            let clock = ContinuousClock()
            let started = clock.now
            let input = pcm + Data(repeating: 0, count: 64_000)
            for offset in stride(from: 0, to: input.count, by: 3200) {
                if client.isFailed { break }
                client.sendAudio(input.subdata(in: offset..<min(offset + 3200, input.count)))
                try await clock.sleep(until: started + .milliseconds((offset / 3200 + 1) * 100))
            }
            await client.finish()
        } else {
            client.close()
        }
        let summary = try log.complete(mode: mode, seconds: Double(pcm.count) / 32_000)
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        guard summary["passed"] as? Bool == true else {
            throw ReplayError(message: "Doubao replay failed; see the JSONL trace")
        }
    }
}
