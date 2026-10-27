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
        case finalAudio(Data)
        case done
        case failed(String)
        case ignored
    }

    static func parseSynthesisLine(_ line: String) -> SynthesisLine {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignored }
        guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))
                as? [String: Any], let code = object["code"] as? Int else {
            return .failed("invalid synthesis response")
        }
        if code != 0, code != 20_000_000 {
            return .failed("\(code): \(object["message"] as? String ?? "synthesis failed")")
        }
        let isDone = code == 20_000_000 || object["done"] as? Bool == true
        if let encoded = object["data"] as? String, !encoded.isEmpty {
            guard let audio = Data(base64Encoded: encoded) else {
                return .failed("invalid synthesis audio")
            }
            return isDone ? .finalAudio(audio) : .audio(audio)
        }
        if isDone { return .done }
        return .ignored
    }

    /// Speaks `text` in `speaker`'s voice, handing 24 kHz mono Int16 PCM to
    /// `onAudio` as it streams in. Throws on a service error; returns once
    /// the service confirms completion. An incomplete stream is a failure.
    static func synthesize(
        text: String, speaker: String, language: String?,
        credentials: CredentialStore.DoubaoCredentials,
        session: URLSession = .shared,
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
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 400 { break } }
            throw ServiceError(message: "HTTP \(http.statusCode): \(body)")
        }
        var receivedAudio = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            switch parseSynthesisLine(line) {
            case .audio(let audio):
                receivedAudio = true
                onAudio(audio)
            case .finalAudio(let audio):
                onAudio(audio)
                return
            case .done:
                guard receivedAudio else { throw ServiceError(message: "synthesis returned no audio") }
                return
            case .failed(let message): throw ServiceError(message: message)
            case .ignored: continue
            }
        }
        try Task.checkCancellation()
        throw ServiceError(message: "synthesis stream ended before completion")
    }

    // MARK: - voice cloning

    enum CloneStatus: Int, Sendable, Equatable {
        case notFound = 0
        case training = 1
        case ready = 2
        case failed = 3
        case active = 4

        var isUsable: Bool { self == .ready || self == .active }
    }

    /// V3 enrollment is shared by TTS and end-to-end realtime speech. A
    /// console-allocated slot and a customer-named slot use different wire
    /// fields; a custom name must never be mistaken for an allocated slot.
    enum VoiceIdentifier: Sendable, Equatable {
        case allocated(String)
        case custom(String)

        var effectiveSpeakerID: String {
            switch self {
            case .allocated(let value), .custom(let value): value
            }
        }
    }

    struct VoicePreview: Sendable, Equatable {
        let modelType: Int
        let url: URL
    }

    struct VoiceTrainingResult: Sendable, Equatable {
        let speakerID: String
        let status: CloneStatus
        let remainingTrainingTimes: Int?
        let language: Int?
        let previews: [VoicePreview]
    }

    /// A timeout or an ambiguous server response may follow a successful
    /// upload. Keep the identity and request ID so callers can query the
    /// existing enrollment instead of spending another training attempt.
    struct VoiceTrainingError: LocalizedError, Equatable, Sendable {
        let message: String
        var requestID: String? = nil
        var speakerID: String? = nil
        var outcomeUnknown: Bool = false
        var logID: String? = nil

        var errorDescription: String? { message }
    }

    static let maximumRealtimeTrainingBytes = 10 * 1_024 * 1_024
    static let realtimeTrainingFormats: Set<String> = ["wav", "mp3", "ogg", "m4a", "aac", "pcm"]
    private static let realtimeTrainingLanguages = ["zh": 0, "cn": 0, "en": 1]
    // The provider's exact reserved-name rule, including its case-sensitive
    // two-letter language prefix. Do not make the entire expression caseless.
    private static let reservedCustomVoicePattern = #"^((?i:S_|ICL_|MIX_|DiT_|BV)|[a-z]{2}_|(?i:(wvae|moon|mercury|venus|earth|mars|jupiter|saturn|uranus|neptune|pluto|umm)_)).*|.*_(?i:bigtts|bigtts_cc|tob|cs_tob|streaming)$|^[^a-zA-Z]|.*[-_]$|^.{0,7}$|^.{257,}$|.*[^a-zA-Z0-9_-].*"#

    static func validateRealtimeVoiceIdentifier(_ voice: VoiceIdentifier) throws {
        let value = voice.effectiveSpeakerID
        let valid: Bool
        switch voice {
        case .allocated:
            valid = value.range(of: #"^S_[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
        case .custom:
            valid = value.range(of: reservedCustomVoicePattern, options: .regularExpression) == nil
        }
        guard valid else {
            throw VoiceTrainingError(
                message: "invalid voice identifier", speakerID: value
            )
        }
    }

    /// PCM is raw 24 kHz mono audio. Container decoding and sample quality
    /// are ultimately validated by the provider; the UI can show duration.
    static func validateRealtimeTrainingSample(_ audio: Data, format: String, language: String) throws {
        guard !audio.isEmpty, audio.count <= maximumRealtimeTrainingBytes else {
            throw VoiceTrainingError(message: "voice sample must contain 1 byte to 10 MB")
        }
        guard realtimeTrainingFormats.contains(format.lowercased()) else {
            throw VoiceTrainingError(message: "unsupported voice sample format")
        }
        guard realtimeTrainingLanguages[language] != nil else {
            throw VoiceTrainingError(message: "realtime voice training supports Chinese and English samples")
        }
    }

    /// Upload exactly once. This does not activate a postpaid voice or
    /// synthesize its preview. The returned preview URLs are metadata only.
    static func trainRealtimeVoice(
        _ audio: Data, format: String, voice: VoiceIdentifier, transcript: String = "",
        language: String, credentials: CredentialStore.DoubaoCredentials,
        requestID: String? = nil,
        session: URLSession = .shared
    ) async throws -> VoiceTrainingResult {
        try validateRealtimeVoiceIdentifier(voice)
        try validateRealtimeTrainingSample(audio, format: format, language: language)
        var body = realtimeVoiceIdentityBody(voice)
        body["audio"] = ["data": audio.base64EncodedString(), "format": format.lowercased()]
        body["language"] = realtimeTrainingLanguages[language]!
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { body["text"] = text }
        return try await postRealtimeVoiceJSON(
            "api/v3/tts/voice_clone", body: body, voice: voice,
            credentials: credentials, session: session, providedRequestID: requestID
        )
    }

    static func realtimeVoiceStatus(
        voice: VoiceIdentifier, credentials: CredentialStore.DoubaoCredentials,
        session: URLSession = .shared
    ) async throws -> VoiceTrainingResult {
        try validateRealtimeVoiceIdentifier(voice)
        return try await postRealtimeVoiceJSON(
            "api/v3/tts/get_voice", body: realtimeVoiceIdentityBody(voice), voice: voice,
            credentials: credentials, session: session
        )
    }

    private static func realtimeVoiceIdentityBody(_ voice: VoiceIdentifier) -> [String: Any] {
        switch voice {
        case .allocated(let value): ["speaker_id": value]
        case .custom(let value): ["speaker_id": "custom_speaker_id", "custom_speaker_id": value]
        }
    }

    private static func postRealtimeVoiceJSON(
        _ path: String, body: [String: Any], voice: VoiceIdentifier,
        credentials: CredentialStore.DoubaoCredentials, session: URLSession,
        providedRequestID: String? = nil
    ) async throws -> VoiceTrainingResult {
        guard !credentials.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceTrainingError(message: "voice training credentials are missing",
                                     speakerID: voice.effectiveSpeakerID)
        }
        if let providedRequestID, UUID(uuidString: providedRequestID) == nil {
            throw VoiceTrainingError(message: "invalid voice training request ID",
                                     requestID: providedRequestID, speakerID: voice.effectiveSpeakerID)
        }
        let requestID = providedRequestID ?? UUID().uuidString
        var serverLogID: String?
        func failure(_ message: String, unknown: Bool) -> VoiceTrainingError {
            VoiceTrainingError(message: message, requestID: requestID,
                               speakerID: voice.effectiveSpeakerID, outcomeUnknown: unknown,
                               logID: serverLogID)
        }
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(requestID, forHTTPHeaderField: "X-Api-Request-Id")
        if credentials.appID.isEmpty {
            request.setValue(credentials.accessToken, forHTTPHeaderField: "X-Api-Key")
        } else {
            request.setValue(credentials.appID, forHTTPHeaderField: "X-Api-App-Key")
            request.setValue(credentials.accessToken, forHTTPHeaderField: "X-Api-Access-Key")
        }
        // V3 enrollment has no resource-ID header. The TTS resource selects
        // the rendering product later, when a voice is actually used.
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Cancellation can race a completed upload as well. Never turn
            // any transport failure into an automatic resubmission.
            let detail = (error as? URLError).map { " (\($0.code.rawValue))" } ?? ""
            throw failure("voice training response was not received\(detail); query the existing voice before retrying",
                          unknown: true)
        }
        guard let http = response as? HTTPURLResponse else {
            throw failure("voice training response is missing HTTP status", unknown: true)
        }
        serverLogID = http.value(forHTTPHeaderField: "X-Tt-Logid")
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = object.flatMap { realtimeVoiceInteger($0["code"]) }
        let isAmbiguousFailure = http.statusCode == 408 || http.statusCode >= 500
            || code.map { (50_000_000..<60_000_000).contains($0) } == true
        let hasFailureCode = code.map { $0 != 0 && $0 != 20_000_000 } == true
        if !(200..<300).contains(http.statusCode) || hasFailureCode {
            var details = "HTTP \(http.statusCode)"
            if let code { details += " (\(code))" }
            if let message = object?["message"] as? String, !message.isEmpty {
                // Never include the raw body: it may contain a sample or
                // credentials. Only include a bounded, redacted diagnostic.
                let redacted = message.replacingOccurrences(of: credentials.accessToken, with: "[redacted]")
                    .replacingOccurrences(of: #"[A-Za-z0-9+/=]{80,}"#, with: "[redacted]",
                                          options: .regularExpression)
                details += ": " + String(redacted.prefix(400))
            }
            throw failure(details, unknown: isAmbiguousFailure)
        }
        guard let object else {
            throw failure("invalid voice training response; query the existing voice before retrying", unknown: true)
        }
        if object["code"] != nil, code == nil {
            throw failure("voice training response contains an invalid code", unknown: true)
        }
        guard let rawStatus = realtimeVoiceInteger(object["status"]),
              let status = CloneStatus(rawValue: rawStatus) else {
            throw failure("voice training response contains no valid status", unknown: true)
        }
        guard let rawSpeakerID = object["speaker_id"] as? String,
              !rawSpeakerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw failure("voice training response is missing speaker_id", unknown: true)
        }
        var speakerID = rawSpeakerID
        if rawSpeakerID == "custom_speaker_id" {
            guard let customID = object["custom_speaker_id"] as? String,
                  !customID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw failure("voice training response is missing custom_speaker_id", unknown: true)
            }
            speakerID = customID
        }
        let previews = (object["speaker_status"] as? [[String: Any]] ?? []).compactMap { item -> VoicePreview? in
            guard let modelType = realtimeVoiceInteger(item["model_type"]),
                  let value = item["demo_audio"] as? String, let url = URL(string: value),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil else { return nil }
            return VoicePreview(modelType: modelType, url: url)
        }
        return VoiceTrainingResult(
            speakerID: speakerID, status: status,
            remainingTrainingTimes: realtimeVoiceInteger(object["available_training_times"]),
            language: realtimeVoiceInteger(object["language"]), previews: previews
        )
    }

    private static func realtimeVoiceInteger(_ value: Any?) -> Int? {
        // JSON booleans and fractional numbers must not masquerade as
        // success status 1/2 or consume a training allowance in the UI.
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              let result = Int(number.stringValue) else { return nil }
        return result
    }

    /// Uploads a 10–30 second sample of the user speaking to train
    /// `speakerID`, which must already be allotted to the account in the
    /// console. Training takes seconds to minutes; poll `cloneStatus`.
    static func uploadSample(
        _ audio: Data, format: String, speakerID: String, transcript: String = "",
        language: String? = nil, credentials: CredentialStore.DoubaoCredentials,
        session: URLSession = .shared
    ) async throws {
        try requireAppID(credentials)
        let body = uploadBody(audio, format: format, speakerID: speakerID,
                              transcript: transcript, language: language,
                              appID: credentials.appID)
        let reply = try await postJSON("api/v1/mega_tts/audio/upload", body, credentials, session)
        try checkBaseResponse(reply)
    }

    /// What the sample upload sends. The transcript of what the sample
    /// says is optional, but lets the service check the recording against it.
    static func uploadBody(
        _ audio: Data, format: String, speakerID: String, transcript: String,
        language: String? = nil, appID: String
    ) -> [String: Any] {
        var sample: [String: Any] = ["audio_bytes": audio.base64EncodedString(), "audio_format": format]
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { sample["text"] = text }
        var body: [String: Any] = [
            "appid": appID,
            "speaker_id": speakerID,
            "audios": [sample],
            "source": 2,
            // Voice cloning 2.0.
            "model_type": 4,
        ]
        // The service assumes Chinese unless told otherwise.
        if let language, let code = sampleLanguages[language] { body["language"] = code }
        return body
    }

    /// The enrollment's `language` enum, for the languages it trains.
    static let sampleLanguages = ["zh": 0, "en": 1, "ja": 2, "es": 3, "id": 4, "pt": 5]

    static func cloneStatus(
        speakerID: String, credentials: CredentialStore.DoubaoCredentials,
        session: URLSession = .shared
    ) async throws -> CloneStatus {
        try requireAppID(credentials)
        let reply = try await postJSON(
            "api/v1/mega_tts/status",
            ["appid": credentials.appID, "speaker_id": speakerID], credentials, session
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
        _ credentials: CredentialStore.DoubaoCredentials, _ session: URLSession
    ) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request, credentials: credentials, resourceID: cloneResourceID)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ServiceError(
                message: "HTTP \(http.statusCode): \(String(decoding: data.prefix(400), as: UTF8.self))"
            )
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError(message: "invalid voice cloning response")
        }
        return object
    }

    private static func checkBaseResponse(_ reply: [String: Any]) throws {
        guard let base = reply["BaseResp"] as? [String: Any],
              let code = base["StatusCode"] as? Int else {
            throw ServiceError(message: "voice cloning response is missing BaseResp.StatusCode")
        }
        guard code == 0 else {
            throw ServiceError(message: "\(code): \(base["StatusMessage"] as? String ?? "request failed")")
        }
    }
}
