import Foundation
import Synchronization

/// Build with the production TranslationClient, CredentialStore, ServerItemLinks
/// and BridgeLog sources (-D DEBUG). Input is 16 kHz mono signed little-endian PCM.
@main struct ReplayTranslation {
    static func main() async throws {
        let args = CommandLine.arguments
        guard (3...5).contains(args.count) else { fatalError("usage: replay-translation input.pcm output.jsonl [text|audio] [preset|once|always]") }
        let wantsAudio = args.count == 3 || args[3] == "audio"
        guard args.count == 3 || ["text", "audio"].contains(args[3]) else { fatalError("Unknown output modality") }
        let voiceMode = args.count > 4 ? args[4] : "preset"
        guard ["preset", "once", "always"].contains(voiceMode) else { fatalError("Unknown voice mode") }
        let voice: TranslationClient.Config.Voice = voiceMode == "once" ? .cloneOnce : voiceMode == "always" ? .cloneEachReply : .preset
        let credentials = CredentialStore.load()
        guard credentials.isComplete else { fatalError("Model Studio credentials unavailable") }
        let pcm = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        let config = TranslationClient.Config(apiKey: credentials.apiKey, workspaceID: credentials.workspaceID,
                                             targetLanguage: "zh", sourceLanguage: "en", wantsAudio: wantsAudio, voice: voice)
        let client = TranslationClient(config: config, diagnosticLabel: "file-replay")
        guard !FileManager.default.fileExists(atPath: args[2]) else { fatalError("Trace output already exists") }
        FileManager.default.createFile(atPath: args[2], contents: nil)
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: args[2]))
        let pcmPath = args[2] + ".pcm"
        guard !FileManager.default.fileExists(atPath: pcmPath) else { fatalError("Audio output already exists") }
        FileManager.default.createFile(atPath: pcmPath, contents: nil)
        let audioFile = try FileHandle(forWritingTo: URL(fileURLWithPath: pcmPath))
        let finished = Mutex(false)
        let started = Date()
        client.onRawFrameForTesting = { frame in
            guard var json = try? JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any] else { return }
            // Preserve protocol, text and byte counts, never the audio payload.
            if json["type"] as? String == "response.audio.delta", let encoded = json["delta"] as? String {
                let bytes = Data(base64Encoded: encoded) ?? Data()
                try? audioFile.write(contentsOf: bytes)
                json["audio_bytes"] = bytes.count
                json.removeValue(forKey: "delta")
            }
            json["receipt_seconds"] = Date().timeIntervalSince(started)
            if let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) {
                try? output.write(contentsOf: data + Data([10]))
            }
        }
        client.onEvent = { event in
            if case .finished = event.payload { finished.withLock { $0 = true } }
        }
        client.connect()
        guard await client.waitUntilReady() else { client.close(); fatalError("Session setup failed") }
        let clock = ContinuousClock()
        let sendStart = clock.now
        // Fixed pacing prevents throughput from changing the audio timeline.
        let input = pcm + Data(repeating: 0, count: 64_000)
        for offset in stride(from: 0, to: input.count, by: 3200) {
            client.sendAudio(input.subdata(in: offset..<min(offset + 3200, input.count)))
            try await clock.sleep(until: sendStart + .milliseconds((offset / 3200 + 1) * 100))
        }
        await client.finish()
        client.onRawFrameForTesting = nil
        try output.close()
        try audioFile.close()
        guard finished.withLock({ $0 }) else { fatalError("Service did not finish before timeout; trace is incomplete") }
        print("input_seconds=\(Double(pcm.count) / 32000) session_finished=\(finished.withLock { $0 })")
    }
}
