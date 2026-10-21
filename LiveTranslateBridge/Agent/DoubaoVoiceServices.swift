import os
import Foundation

/// The two Doubao speech calls the call agent needs besides interpretation:
/// training a voice from the user's sample, and speaking text in it.
///
/// Both are plain HTTPS. Synthesis streams newline-delimited JSON, one
/// base64 audio chunk per line, which is fed to the player as it arrives so
/// the first words go out before the whole reply is rendered.
nonisolated enum DoubaoVoiceServices {
    static let baseURL = URL(string: "https://openspeech.bytedance.com")!
    /// Voice cloning 2.0, which both trains and speaks `S_…` voices.
    static let cloneResourceID = "seed-icl-2.0"
    /// Stock voices.
    static let presetResourceID = "seed-tts-2.0"
    /// The model cloned voices are rendered with.
    static let cloneModel = "seed-tts-2.0-standard"

    struct ServiceError: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// Applies whichever login the user has: App ID with Access Token
    /// (sent under every header name the speech products use), or the new
    /// console's single API key.
    static func authorize(
        _ request: inout URLRequest, credentials: CredentialStore.DoubaoCredentials,
        resourceID: String
    ) {
        if credentials.appID.isEmpty {
            request.setValue(credentials.accessToken, forHTTPHeaderField: "X-Api-Key")
        } else {
            request.setValue(credentials.appID, forHTTPHeaderField: "X-Api-App-Id")
            request.setValue(credentials.appID, forHTTPHeaderField: "X-Api-App-Key")
            request.setValue(credentials.accessToken, forHTTPHeaderField: "X-Api-Access-Key")
            // The v1 voice-cloning endpoints still read the old scheme.
            request.setValue("Bearer;\(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(resourceID, forHTTPHeaderField: "Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
    }

    // MARK: - synthesis

    /// The body of a v3 unidirectional synthesis request. Separate so the
    /// tests can pin it.
    static func synthesisBody(text: String, speaker: String, language: String?) -> [String: Any] {
        var params: [String: Any] = [
            "text": text,
            "speaker": speaker,
            "audio_params": [
                "format": "pcm",
                // What `TranslationPlayer` plays.
                "sample_rate": 24_000,
            ],
        ]
        if speaker.hasPrefix("S_") {
            // Cloned voices name the model that speaks them; the standard
            // one is the lower-latency of the two, which a call wants.
            params["model"] = cloneModel
        }
        if let language, let data = try? JSONSerialization.data(
            withJSONObject: ["explicit_language": language]
        ) {
            params["additions"] = String(decoding: data, as: UTF8.self)
        }
        return ["user": ["uid": "livetranslate-bridge"], "req_params": params]
    }

    /// One line of the synthesis stream: audio, the end, or a failure.
    enum SynthesisLine: Equatable {
        case audio(Data)
        case done
        case failed(String)
        case ignored
    }

    static func parseSynthesisLine(_ line: String) -> SynthesisLine {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))
                as? [String: Any] else { return .ignored }
        let code = (object["code"] as? Int) ?? 0
        if code != 0, code != 20_000_000 {
            return .failed("\(code): \(object["message"] as? String ?? "synthesis failed")")
        }
        if let encoded = object["data"] as? String, !encoded.isEmpty,
           let audio = Data(base64Encoded: encoded) {
            return .audio(audio)
        }
        if code == 20_000_000 || object["done"] as? Bool == true { return .done }
        return .ignored
    }

    /// Speaks `text` in `speaker`'s voice, handing 24 kHz mono Int16 PCM to
    /// `onAudio` as it streams in. Throws on a service error; returns once
    /// the stream ends or the task is cancelled.
    static func synthesize(
        text: String, speaker: String, language: String?,
        credentials: CredentialStore.DoubaoCredentials,
        onAudio: @Sendable (Data) -> Void
    ) async throws {
        var request = URLRequest(url: baseURL.appending(path: "api/v3/tts/unidirectional"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request, credentials: credentials,
                  resourceID: speaker.hasPrefix("S_") ? cloneResourceID : presetResourceID)
        request.httpBody = try JSONSerialization.data(
            withJSONObject: synthesisBody(text: text, speaker: speaker, language: language)
        )
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 400 { break } }
            throw ServiceError(message: "HTTP \(http.statusCode): \(body)")
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            switch parseSynthesisLine(line) {
            case .audio(let audio): onAudio(audio)
            case .done: return
            case .failed(let message): throw ServiceError(message: message)
            case .ignored: continue
            }
        }
    }

    // MARK: - voice cloning

    enum CloneStatus: Int, Sendable {
        case notFound = 0
        case training = 1
        case ready = 2
        case failed = 3
        case active = 4

        var isUsable: Bool { self == .ready || self == .active }
    }

    /// Uploads a 10–30 second sample of the user speaking to train
    /// `speakerID`, which must already be allotted to the account in the
    /// console. Training takes seconds to minutes; poll `cloneStatus`.
    static func uploadSample(
        _ audio: Data, format: String, speakerID: String, transcript: String = "",
        credentials: CredentialStore.DoubaoCredentials
    ) async throws {
        try requireAppID(credentials)
        let body = uploadBody(audio, format: format, speakerID: speakerID,
                              transcript: transcript, appID: credentials.appID)
        let reply = try await postJSON("api/v1/mega_tts/audio/upload", body, credentials)
        try checkBaseResponse(reply)
    }

    /// What the sample upload sends. The transcript of what the sample
    /// says is optional, but lets the service check the recording against it.
    static func uploadBody(
        _ audio: Data, format: String, speakerID: String, transcript: String, appID: String
    ) -> [String: Any] {
        var sample: [String: Any] = ["audio_bytes": audio.base64EncodedString(), "audio_format": format]
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { sample["text"] = text }
        return [
            "appid": appID,
            "speaker_id": speakerID,
            "audios": [sample],
            "source": 2,
            // Voice cloning 2.0.
            "model_type": 4,
        ]
    }

    static func cloneStatus(
        speakerID: String, credentials: CredentialStore.DoubaoCredentials
    ) async throws -> CloneStatus {
        try requireAppID(credentials)
        let reply = try await postJSON(
            "api/v1/mega_tts/status",
            ["appid": credentials.appID, "speaker_id": speakerID], credentials
        )
        try checkBaseResponse(reply)
        let raw = reply["status"] as? Int ?? 0
        return CloneStatus(rawValue: raw) ?? .notFound
    }

    /// The v1 cloning endpoints read the App ID from the body and do not
    /// take the new console's API key.
    private static func requireAppID(_ credentials: CredentialStore.DoubaoCredentials) throws {
        guard !credentials.appID.isEmpty else {
            throw ServiceError(message: "voice cloning needs the App ID and Access Token login")
        }
    }

    private static func postJSON(
        _ path: String, _ body: [String: Any],
        _ credentials: CredentialStore.DoubaoCredentials
    ) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request, credentials: credentials, resourceID: cloneResourceID)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ServiceError(
                message: "HTTP \(http.statusCode): \(String(decoding: data.prefix(400), as: UTF8.self))"
            )
        }
        return object
    }

    private static func checkBaseResponse(_ reply: [String: Any]) throws {
        guard let base = reply["BaseResp"] as? [String: Any] else { return }
        let code = base["StatusCode"] as? Int ?? 0
        guard code == 0 else {
            throw ServiceError(message: "\(code): \(base["StatusMessage"] as? String ?? "request failed")")
        }
    }
}
