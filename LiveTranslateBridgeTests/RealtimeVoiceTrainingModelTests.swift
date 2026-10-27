import Foundation
import Testing
@testable import LiveTranslateBridge

private nonisolated func trainingResponse(_ status: DoubaoVoiceServices.CloneStatus,
                                          speaker: String = "S_fixture", remaining: Int? = 14)
    -> DoubaoVoiceServices.VoiceTrainingResult {
    .init(speakerID: speaker, status: status, remainingTrainingTimes: remaining,
          language: 1, previews: [])
}

private actor VoiceEnrollmentFixture {
    var submissions = 0
    var queries = 0
    var submittedRequestID: String?
    var queriedVoice: DoubaoVoiceServices.VoiceIdentifier?
    var submissionResult: DoubaoVoiceServices.VoiceTrainingResult
    var queryResult: DoubaoVoiceServices.VoiceTrainingResult
    var submissionError: DoubaoVoiceServices.VoiceTrainingError?
    var queryError: DoubaoVoiceServices.VoiceTrainingError?
    private var holdSubmission: Bool
    private var continuation: CheckedContinuation<Void, Never>?

    init(submissionResult: DoubaoVoiceServices.VoiceTrainingResult = trainingResponse(.training),
         queryResult: DoubaoVoiceServices.VoiceTrainingResult = trainingResponse(.ready),
         submissionError: DoubaoVoiceServices.VoiceTrainingError? = nil,
         queryError: DoubaoVoiceServices.VoiceTrainingError? = nil, holdSubmission: Bool = false) {
        self.submissionResult = submissionResult
        self.queryResult = queryResult
        self.submissionError = submissionError
        self.queryError = queryError
        self.holdSubmission = holdSubmission
    }

    nonisolated var services: RealtimeVoiceTrainingModel.Services {
        .init(train: { [self] _, _, _, _, _, _, requestID in
            try await train(requestID: requestID)
        }, query: { [self] voice, _ in
            try await query(voice: voice)
        })
    }

    func train(requestID: String) async throws -> DoubaoVoiceServices.VoiceTrainingResult {
        submissions += 1
        submittedRequestID = requestID
        if holdSubmission { await withCheckedContinuation { continuation = $0 } }
        if let submissionError { throw submissionError }
        return submissionResult
    }

    func query(voice: DoubaoVoiceServices.VoiceIdentifier) throws -> DoubaoVoiceServices.VoiceTrainingResult {
        queries += 1
        queriedVoice = voice
        if let queryError { throw queryError }
        return queryResult
    }

    func rejectNextQuery() {
        queryError = .init(message: "HTTP 403 (45000030): resource denied", requestID: "query-id",
                           logID: "query-log")
    }

    func release() {
        holdSubmission = false
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
struct RealtimeVoiceTrainingModelTests {
    private let credentials = CredentialStore.DoubaoCredentials(appID: "", accessToken: "key-never-persist")
    private let sample = Data("recording-never-persist".utf8)

    private func makeModel(_ fixture: VoiceEnrollmentFixture)
        throws -> (RealtimeVoiceTrainingModel, UserDefaults, String) {
        let name = "realtimeVoiceTraining.pending.v1"
        var memoryStore: UserDefaults!
        SubtitleModel.withTemporaryDefaults { memoryStore = SubtitleModel.defaultsStoreForTesting }
        let store = try #require(memoryStore)
        let model = RealtimeVoiceTrainingModel(services: fixture.services, defaults: store)
        model.voiceID = "S_fixture"
        model.language = "en"
        try model.setSample(sample, format: "wav", fileName: "sample.wav")
        return (model, store, name)
    }

    @Test func trainingPendingBlocksAnotherSubmissionUntilStatusQuery() async throws {
        let fixture = VoiceEnrollmentFixture()
        let (model, store, name) = try makeModel(fixture)
        defer { store.removeObject(forKey: name) }
        await model.submit(credentials: credentials)
        #expect(model.phase == .training)
        #expect(model.requiresQuery)
        #expect(model.result?.remainingTrainingTimes == 14)
        await model.submit(credentials: credentials)
        #expect(await fixture.submissions == 1)
        await model.query(credentials: credentials)
        #expect(model.phase == .ready)
        #expect(!model.requiresQuery)
        #expect(model.usableVoiceID() == "S_fixture")
        #expect(await fixture.queries == 1)
    }

    @Test func inFlightRequestIdentityIsPersistedBeforeCloudMutationAndDuplicateIsBlocked() async throws {
        let fixture = VoiceEnrollmentFixture(holdSubmission: true)
        let (model, store, name) = try makeModel(fixture)
        defer { store.removeObject(forKey: name) }
        let submission = Task { await model.submit(credentials: credentials) }
        for _ in 0..<100 {
            if await fixture.submissions > 0 { break }
            await Task.yield()
        }
        #expect(model.phase == .submitting)
        let requestID = try #require(model.pendingAttempt?.requestID)
        #expect(UUID(uuidString: requestID) != nil)
        #expect(await fixture.submittedRequestID == requestID)
        let reopened = RealtimeVoiceTrainingModel(services: fixture.services, defaults: store)
        #expect(reopened.requestID == requestID)
        #expect(reopened.phase == .outcomeUnknown)
        await reopened.submit(credentials: credentials)
        await model.submit(credentials: credentials)
        #expect(await fixture.submissions == 1)
        await fixture.release()
        await submission.value
        #expect(model.pendingAttempt?.requestID == requestID)
    }

    @Test func ambiguousUploadRestoresIdentityWithoutRecordingCredentialsOrTranscript() async throws {
        let fixture = VoiceEnrollmentFixture(submissionError: .init(message: "response lost", outcomeUnknown: true))
        let (model, store, name) = try makeModel(fixture)
        defer { store.removeObject(forKey: name) }
        model.voiceKind = .custom
        model.voiceID = "LiveTranslateFixture_123456"
        model.transcript = "private transcript never persist"
        await model.submit(credentials: credentials)
        #expect(model.phase == .outcomeUnknown)
        let submittedRequestID = try #require(model.requestID)
        let raw = try #require(store.data(forKey: "realtimeVoiceTraining.pending.v1"))
        let stored = String(decoding: raw, as: UTF8.self)
        #expect(!stored.contains(credentials.accessToken))
        #expect(!stored.contains(String(decoding: sample, as: UTF8.self)))
        #expect(!stored.contains(model.transcript))
        let reopened = RealtimeVoiceTrainingModel(services: fixture.services, defaults: store)
        #expect(reopened.voiceKind == .custom)
        #expect(reopened.voiceID == model.voiceID)
        #expect(reopened.language == "en")
        #expect(reopened.requestID == submittedRequestID)
        #expect(reopened.sampleName == nil)
        #expect(reopened.transcript.isEmpty)
        await reopened.query(credentials: credentials)
        #expect(await fixture.queriedVoice == .custom("LiveTranslateFixture_123456"))
        #expect(reopened.usableVoiceID() == "S_fixture")
        #expect(store.data(forKey: "realtimeVoiceTraining.pending.v1") == nil)
    }

    @Test func serviceRejectionRetainsDiagnosticAndDoesNotPretendTrainingSucceeded() async throws {
        let fixture = VoiceEnrollmentFixture(submissionError: .init(
            message: "HTTP 403 (45000030): resource denied", requestID: "submission-id",
            speakerID: "S_fixture", logID: "provider-log"
        ))
        let (model, store, name) = try makeModel(fixture)
        defer { store.removeObject(forKey: name) }
        await model.submit(credentials: credentials)
        #expect(model.phase == .rejected)
        #expect(model.requestID == "submission-id")
        #expect(model.logID == "provider-log")
        #expect(model.usableVoiceID() == nil)
        #expect(model.pendingAttempt == nil)
        #expect(await fixture.submissions == 1)
    }

    @Test func failedRecoveryQueryKeepsOriginalSubmissionRequestIdentity() async throws {
        let fixture = VoiceEnrollmentFixture(submissionError: .init(message: "timeout", outcomeUnknown: true))
        let (model, store, name) = try makeModel(fixture)
        defer { store.removeObject(forKey: name) }
        await model.submit(credentials: credentials)
        let originalID = try #require(model.pendingAttempt?.requestID)
        await fixture.rejectNextQuery()
        await model.query(credentials: credentials)
        #expect(model.phase == .outcomeUnknown)
        #expect(model.requestID == originalID)
        #expect(model.pendingAttempt?.requestID == originalID)
        #expect(model.lastQueryRequestID == "query-id")
        let reopened = RealtimeVoiceTrainingModel(services: fixture.services, defaults: store)
        #expect(reopened.pendingAttempt?.requestID == originalID)
        await model.submit(credentials: credentials)
        #expect(await fixture.submissions == 1)
    }

    @Test func aFailedQueryInvalidatesPreviouslyReadyVoice() async throws {
        let fixture = VoiceEnrollmentFixture(submissionResult: trainingResponse(.ready))
        let (model, store, name) = try makeModel(fixture)
        defer { store.removeObject(forKey: name) }
        await model.submit(credentials: credentials)
        #expect(model.usableVoiceID() == "S_fixture")
        await fixture.rejectNextQuery()
        await model.query(credentials: credentials)
        #expect(model.phase == .rejected)
        #expect(model.result == nil)
        #expect(model.usableVoiceID() == nil)
    }

    @Test func selectedIdentityMustMatchSuccessfulResultAndUsesReturnedID() async throws {
        let fixture = VoiceEnrollmentFixture(submissionResult: trainingResponse(.ready, speaker: "S_returned"))
        let (model, store, name) = try makeModel(fixture)
        defer { store.removeObject(forKey: name) }
        await model.submit(credentials: credentials)
        #expect(model.usableVoiceID() == "S_returned")
        model.voiceID = "S_other"
        #expect(model.usableVoiceID() == nil)
    }

    @Test func runningCallBlocksSubmissionAndApplyingButStatusQueryStaysReadOnly() async throws {
        let fixture = VoiceEnrollmentFixture()
        let (model, store, name) = try makeModel(fixture)
        defer { store.removeObject(forKey: name) }
        await model.submit(credentials: credentials, isCallRunning: true)
        #expect(await fixture.submissions == 0)
        await model.query(credentials: credentials)
        #expect(model.phase == .ready)
        #expect(model.usableVoiceID(isCallRunning: true) == nil)
        #expect(model.usableVoiceID() == "S_fixture")
    }

    @Test func failedAndMissingVoicesResolvePendingWithoutBeingUsable() async throws {
        for status in [DoubaoVoiceServices.CloneStatus.failed, .notFound] {
            let fixture = VoiceEnrollmentFixture(queryResult: trainingResponse(status))
            let (model, store, name) = try makeModel(fixture)
            defer { store.removeObject(forKey: name) }
            await model.submit(credentials: credentials)
            await model.query(credentials: credentials)
            #expect(model.phase == (status == .failed ? .failed : .notFound))
            #expect(model.pendingAttempt == nil)
            #expect(model.usableVoiceID() == nil)
        }
    }

    @Test func invalidSampleIdentifierAndMissingKeyNeverSubmit() async throws {
        let fixture = VoiceEnrollmentFixture()
        let (model, store, name) = try makeModel(fixture)
        defer { store.removeObject(forKey: name) }
        model.voiceID = "stock_voice"
        await model.submit(credentials: credentials)
        #expect(model.phase == .rejected)
        model.voiceID = "S_fixture"
        await model.submit(credentials: .init(appID: "", accessToken: ""))
        #expect(model.phase == .rejected)
        #expect(throws: DoubaoVoiceServices.VoiceTrainingError.self) {
            try model.setSample(Data(), format: "wav", fileName: "empty.wav")
        }
        await model.submit(credentials: credentials)
        #expect(await fixture.submissions == 0)
        #expect(model.pendingAttempt == nil)
    }

    @Test func newImportClearsPreviousSampleEvenWhenReplacementFails() async throws {
        let fixture = VoiceEnrollmentFixture()
        let (model, store, name) = try makeModel(fixture)
        defer { store.removeObject(forKey: name) }
        #expect(model.canSubmit)
        model.clearSample()
        #expect(!model.canSubmit)
        #expect(model.sampleName == nil)
        #expect(throws: DoubaoVoiceServices.VoiceTrainingError.self) {
            try model.setSample(Data(), format: "wav", fileName: "broken-replacement.wav")
        }
        #expect(!model.canSubmit)
        await model.submit(credentials: credentials)
        #expect(await fixture.submissions == 0)
    }
}
