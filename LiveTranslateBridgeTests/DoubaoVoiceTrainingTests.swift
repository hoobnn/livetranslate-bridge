import Foundation
import os
import Testing
@testable import LiveTranslateBridge

/// Each ephemeral session has an isolated fixture and request ledger. Tests
/// exercise the actual HTTP client without network, keys, or audio playback.
private final class VoiceTrainingProtocol: URLProtocol, @unchecked Sendable {
    struct Fixture {
        var body: String
        var status: Int
        var error: URLError.Code?
        var requests: [URLRequest] = []
    }

    static let fixtures = OSAllocatedUnfairLock(initialState: [String: Fixture]())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: "X-Test-Fixture") ?? ""
        let fixture = Self.fixtures.withLock { values -> Fixture? in
            values[id]?.requests.append(request)
            return values[id]
        }
        guard let fixture else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        if let error = fixture.error {
            client?.urlProtocol(self, didFailWithError: URLError(error))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: fixture.status,
                                       httpVersion: "HTTP/1.1", headerFields: ["X-Tt-Logid": "offline-log-id"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(fixture.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class VoiceTrainingHTTPFixture {
    let id = UUID().uuidString
    let session: URLSession

    init(_ body: String, status: Int = 200, error: URLError.Code? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VoiceTrainingProtocol.self]
        config.httpAdditionalHeaders = ["X-Test-Fixture": id]
        session = URLSession(configuration: config)
        VoiceTrainingProtocol.fixtures.withLock {
            $0[id] = .init(body: body, status: status, error: error)
        }
    }

    deinit {
        session.invalidateAndCancel()
        VoiceTrainingProtocol.fixtures.withLock { _ = $0.removeValue(forKey: id) }
    }

    var requests: [URLRequest] {
        VoiceTrainingProtocol.fixtures.withLock { $0[id]?.requests ?? [] }
    }

    func body(_ index: Int = 0) throws -> [String: Any] {
        let request = try #require(requests.indices.contains(index) ? requests[index] : nil)
        if let data = request.httpBody {
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let stream = try #require(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            guard count > 0 else { break }
            data.append(contentsOf: bytes.prefix(count))
        }
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

struct DoubaoVoiceTrainingTests {
    private let credentials = CredentialStore.DoubaoCredentials(appID: "", accessToken: "offline-test-key")
    private let ready = #"{"status":2,"speaker_id":"S_existing","available_training_times":14,"language":1,"speaker_status":[{"model_type":5,"demo_audio":"https://example.invalid/preview.wav"}]}"#

    @Test func apiKeyEnrollmentUsesV3ContractAndReturnsPreviewMetadataOnly() async throws {
        let fixture = VoiceTrainingHTTPFixture(ready)
        let result = try await DoubaoVoiceServices.trainRealtimeVoice(
            Data([1, 2, 3, 4]), format: "WAV", voice: .allocated("S_existing"),
            transcript: "  This is my own recording.  ", language: "en",
            credentials: credentials, session: fixture.session
        )
        let request = try #require(fixture.requests.first)
        #expect(fixture.requests.count == 1)
        #expect(request.url?.path == "/api/v3/tts/voice_clone")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "offline-test-key")
        #expect(UUID(uuidString: request.value(forHTTPHeaderField: "X-Api-Request-Id") ?? "") != nil)
        #expect(request.value(forHTTPHeaderField: "X-Api-Resource-Id") == nil)
        #expect(request.value(forHTTPHeaderField: "Resource-Id") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try fixture.body()
        #expect(Set(body.keys) == ["speaker_id", "audio", "text", "language"])
        #expect(body["speaker_id"] as? String == "S_existing")
        #expect(body["text"] as? String == "This is my own recording.")
        #expect(body["language"] as? Int == 1)
        let audio = try #require(body["audio"] as? [String: Any])
        #expect(audio["format"] as? String == "wav")
        #expect(audio["data"] as? String == "AQIDBA==")
        #expect(result == .init(
            speakerID: "S_existing", status: .ready, remainingTrainingTimes: 14, language: 1,
            previews: [.init(modelType: 5, url: URL(string: "https://example.invalid/preview.wav")!)]
        ))
    }

    @Test func customEnrollmentAndQueryKeepTheSentinelSeparateFromTheVoiceName() async throws {
        let fixture = VoiceTrainingHTTPFixture(#"{"status":1,"speaker_id":"MyVoice20261023"}"#)
        let voice = DoubaoVoiceServices.VoiceIdentifier.custom("MyVoice20261023")
        _ = try await DoubaoVoiceServices.trainRealtimeVoice(
            Data([1]), format: "pcm", voice: voice, language: "zh",
            credentials: credentials, session: fixture.session
        )
        _ = try await DoubaoVoiceServices.realtimeVoiceStatus(
            voice: voice, credentials: credentials, session: fixture.session
        )
        #expect(fixture.requests.count == 2)
        let training = try fixture.body()
        let query = try fixture.body(1)
        #expect(training["speaker_id"] as? String == "custom_speaker_id")
        #expect(training["custom_speaker_id"] as? String == voice.effectiveSpeakerID)
        #expect(training["language"] as? Int == 0)
        #expect(training["text"] == nil)
        #expect(Set(query.keys) == ["speaker_id", "custom_speaker_id"])
        #expect(query["speaker_id"] as? String == "custom_speaker_id")
        #expect(query["custom_speaker_id"] as? String == voice.effectiveSpeakerID)
        #expect(fixture.requests[1].url?.path == "/api/v3/tts/get_voice")
        #expect(fixture.requests[0].value(forHTTPHeaderField: "X-Api-Request-Id")
                != fixture.requests[1].value(forHTTPHeaderField: "X-Api-Request-Id"))
    }

    @Test func allocatedQueryAndLegacyCredentialsHaveNoV1FieldsOrResourceHeaders() async throws {
        let fixture = VoiceTrainingHTTPFixture(ready)
        let legacy = CredentialStore.DoubaoCredentials(appID: "offline-app", accessToken: "offline-token")
        _ = try await DoubaoVoiceServices.realtimeVoiceStatus(
            voice: .allocated("S_existing"), credentials: legacy, session: fixture.session
        )
        let request = try #require(fixture.requests.first)
        #expect(request.value(forHTTPHeaderField: "X-Api-App-Key") == "offline-app")
        #expect(request.value(forHTTPHeaderField: "X-Api-Access-Key") == "offline-token")
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Api-Resource-Id") == nil)
        let body = try fixture.body()
        #expect(Set(body.keys) == ["speaker_id"])
        #expect(body["speaker_id"] as? String == "S_existing")
    }

    @Test func sampleAndIdentifierValidationHappensBeforeAnyRequest() async {
        let fixture = VoiceTrainingHTTPFixture(ready)
        for invalid in [Data(), Data(repeating: 0, count: DoubaoVoiceServices.maximumRealtimeTrainingBytes + 1)] {
            await #expect(throws: DoubaoVoiceServices.VoiceTrainingError.self) {
                try await DoubaoVoiceServices.trainRealtimeVoice(
                    invalid, format: "wav", voice: .allocated("S_existing"), language: "en",
                    credentials: credentials, session: fixture.session
                )
            }
        }
        for (format, language) in [("aiff", "en"), ("wav", "ja")] {
            await #expect(throws: DoubaoVoiceServices.VoiceTrainingError.self) {
                try await DoubaoVoiceServices.trainRealtimeVoice(
                    Data([1]), format: format, voice: .allocated("S_existing"), language: language,
                    credentials: credentials, session: fixture.session
                )
            }
        }
        await #expect(throws: DoubaoVoiceServices.VoiceTrainingError.self) {
            try await DoubaoVoiceServices.realtimeVoiceStatus(
                voice: .custom("zh_reserved"), credentials: credentials, session: fixture.session
            )
        }
        #expect(fixture.requests.isEmpty)
    }

    @Test func supportedFormatsAndSizeBoundaryAreAccepted() throws {
        for format in ["wav", "mp3", "ogg", "m4a", "aac", "pcm"] {
            try DoubaoVoiceServices.validateRealtimeTrainingSample(Data([1]), format: format, language: "en")
        }
        try DoubaoVoiceServices.validateRealtimeTrainingSample(
            Data(repeating: 0, count: DoubaoVoiceServices.maximumRealtimeTrainingBytes), format: "pcm", language: "cn"
        )
    }

    @Test func reservedCustomNamesAndAllocatedSlotValidationFollowTheProviderRule() throws {
        let invalid = ["", "short", "S_anyvoice", "s_anyvoice", "ICL_voice123", "MIX_voice123",
                       "DiT_voice123", "BVvoice123", "ab_voice123", "zh_custom_voice", "Jupiter_voice",
                       "Name_tob", "name_BIGTTS", "name_cs_tob", "name_streaming", "_abcdefgh",
                       "0abcdefg", "VoiceAbcd_", "VoiceAbcd-", "Voice猫123", "a b c d e", String(repeating: "a", count: 257)]
        for value in invalid {
            #expect(throws: DoubaoVoiceServices.VoiceTrainingError.self) {
                try DoubaoVoiceServices.validateRealtimeVoiceIdentifier(.custom(value))
            }
        }
        for value in ["MyVoice01", "Custom_zh_20261023", "Voice-123", "EN_voice123", String(repeating: "a", count: 256)] {
            try DoubaoVoiceServices.validateRealtimeVoiceIdentifier(.custom(value))
        }
        for value in ["", "S_", "s_voice", "S_white space", "Voice123"] {
            #expect(throws: DoubaoVoiceServices.VoiceTrainingError.self) {
                try DoubaoVoiceServices.validateRealtimeVoiceIdentifier(.allocated(value))
            }
        }
        try DoubaoVoiceServices.validateRealtimeVoiceIdentifier(.allocated("S_existing"))
    }

    @Test(arguments: [
        "", "not JSON", "{}", #"{"status":2}"#, #"{"status":2,"speaker_id":"  "}"#,
        #"{"status":99,"speaker_id":"S_existing"}"#, #"{"status":true,"speaker_id":"S_existing"}"#,
        #"{"status":2.5,"speaker_id":"S_existing"}"#, #"{"status":"2","speaker_id":"S_existing"}"#,
        #"{"code":false,"status":2,"speaker_id":"S_existing"}"#,
        #"{"status":2,"speaker_id":"custom_speaker_id"}"#,
    ])
    func malformedHTTP200IsAnUnknownOutcomeInsteadOfSuccess(_ body: String) async throws {
        let fixture = VoiceTrainingHTTPFixture(body)
        do {
            _ = try await DoubaoVoiceServices.trainRealtimeVoice(
                Data([1]), format: "wav", voice: .allocated("S_existing"), language: "en",
                credentials: credentials, session: fixture.session
            )
            Issue.record("malformed enrollment unexpectedly succeeded")
        } catch let error as DoubaoVoiceServices.VoiceTrainingError {
            #expect(error.outcomeUnknown)
            #expect(error.speakerID == "S_existing")
            #expect(UUID(uuidString: error.requestID ?? "") != nil)
            #expect(error.requestID == fixture.requests.first?.value(forHTTPHeaderField: "X-Api-Request-Id"))
        }
        #expect(fixture.requests.count == 1)
    }

    @Test(arguments: [0, 1, 2, 3, 4])
    func everyDocumentedStatusIsPreservedWithoutAssumingReady(_ rawStatus: Int) async throws {
        let fixture = VoiceTrainingHTTPFixture("{\"status\":\(rawStatus),\"speaker_id\":\"S_existing\"}")
        let result = try await DoubaoVoiceServices.realtimeVoiceStatus(
            voice: .allocated("S_existing"), credentials: credentials, session: fixture.session
        )
        #expect(result.status.rawValue == rawStatus)
        #expect(result.status.isUsable == [2, 4].contains(rawStatus))
        #expect(result.previews.isEmpty)
        #expect(result.remainingTrainingTimes == nil)
    }

    @Test func explicitPermissionFailureIsKnownAndDiagnosticRedactsSecrets() async throws {
        let fixture = VoiceTrainingHTTPFixture(
            #"{"code":45000030,"message":"[resource_id=volc.megatts.timbre] requested resource not granted offline-test-key QUJDREVGQUJDREVGQUJDREVGQUJDREVGQUJDREVGQUJDREVGQUJDREVGQUJDREVGQUJDREVGQUJDREVGQUJDREVG"}"#,
            status: 403
        )
        do {
            _ = try await DoubaoVoiceServices.realtimeVoiceStatus(
                voice: .allocated("S_existing"), credentials: credentials, session: fixture.session
            )
            Issue.record("permission error unexpectedly succeeded")
        } catch let error as DoubaoVoiceServices.VoiceTrainingError {
            #expect(!error.outcomeUnknown)
            #expect(error.message.contains("45000030"))
            #expect(error.message.contains("requested resource not granted"))
            #expect(!error.message.contains("offline-test-key"))
            #expect(!error.message.contains("QUJDREVG"))
            #expect(error.requestID != nil)
            #expect(error.logID == "offline-log-id")
        }
        #expect(fixture.requests.count == 1)
    }

    @Test(arguments: [URLError.Code.timedOut, .networkConnectionLost, .cancelled])
    func transportFailureRetainsRecoveryIdentityAndNeverRetries(_ code: URLError.Code) async throws {
        let fixture = VoiceTrainingHTTPFixture("", error: code)
        do {
            _ = try await DoubaoVoiceServices.trainRealtimeVoice(
                Data([1]), format: "wav", voice: .custom("MyVoice20261023"), language: "en",
                credentials: credentials, session: fixture.session
            )
            Issue.record("transport error unexpectedly succeeded")
        } catch let error as DoubaoVoiceServices.VoiceTrainingError {
            #expect(error.outcomeUnknown)
            #expect(error.speakerID == "MyVoice20261023")
            #expect(error.requestID == fixture.requests.first?.value(forHTTPHeaderField: "X-Api-Request-Id"))
        }
        #expect(fixture.requests.count == 1)
    }

    @Test func serviceFailureOnHTTP200IsStillAnErrorAnd5xxIsUnknown() async throws {
        for (status, body, unknown) in [
            (200, #"{"code":45001109,"message":"WERError","status":2,"speaker_id":"S_existing"}"#, false),
            (408, "", true),
            (503, #"{"code":50001201,"message":"upstream unavailable"}"#, true),
        ] {
            let fixture = VoiceTrainingHTTPFixture(body, status: status)
            do {
                _ = try await DoubaoVoiceServices.trainRealtimeVoice(
                    Data([1]), format: "wav", voice: .allocated("S_existing"), language: "en",
                    credentials: credentials, session: fixture.session
                )
                Issue.record("service error unexpectedly succeeded")
            } catch let error as DoubaoVoiceServices.VoiceTrainingError {
                #expect(error.outcomeUnknown == unknown)
                #expect(error.speakerID == "S_existing")
                #expect(error.requestID != nil)
            }
            #expect(fixture.requests.count == 1)
        }
    }

    @Test func suppliedRequestIDSurvivesDispatchAndAnUnknownResult() async throws {
        let fixture = VoiceTrainingHTTPFixture("", error: .timedOut)
        let requestID = UUID().uuidString
        do {
            _ = try await DoubaoVoiceServices.trainRealtimeVoice(
                Data([1]), format: "wav", voice: .allocated("S_existing"), language: "en",
                credentials: credentials, requestID: requestID, session: fixture.session
            )
            Issue.record("transport error unexpectedly succeeded")
        } catch let error as DoubaoVoiceServices.VoiceTrainingError {
            #expect(error.outcomeUnknown)
            #expect(error.requestID == requestID)
        }
        #expect(fixture.requests.count == 1)
        #expect(fixture.requests.first?.value(forHTTPHeaderField: "X-Api-Request-Id") == requestID)
    }

    @Test func invalidSuppliedRequestIDDoesNotDispatch() async {
        let fixture = VoiceTrainingHTTPFixture(ready)
        await #expect(throws: DoubaoVoiceServices.VoiceTrainingError.self) {
            try await DoubaoVoiceServices.trainRealtimeVoice(
                Data([1]), format: "wav", voice: .allocated("S_existing"), language: "en",
                credentials: credentials, requestID: "", session: fixture.session
            )
        }
        #expect(fixture.requests.isEmpty)
    }

    @Test func malformedPreviewURLsAreNeverExposedAsPlayableAssets() async throws {
        let fixture = VoiceTrainingHTTPFixture(#"{"status":2,"speaker_id":"S_existing","speaker_status":[{"model_type":5,"demo_audio":"file:///private/tmp/untrusted.wav"},{"model_type":5,"demo_audio":"javascript:alert(1)"},{"model_type":5,"demo_audio":"relative.wav"},{"model_type":true,"demo_audio":"https://example.invalid/preview.wav"},{"model_type":4,"demo_audio":"https://example.invalid/preview.wav"}]}"#)
        let result = try await DoubaoVoiceServices.realtimeVoiceStatus(
            voice: .allocated("S_existing"), credentials: credentials, session: fixture.session
        )
        #expect(result.previews.count == 1)
        #expect(result.previews.first?.modelType == 4)
        #expect(fixture.requests.count == 1)
    }
}
