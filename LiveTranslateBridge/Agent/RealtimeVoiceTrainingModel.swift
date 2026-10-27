import Foundation
import Observation

/// Enrollment is a single cloud mutation. Persist only its identity so an
/// interrupted upload can be queried without silently consuming another try.
@MainActor
@Observable
final class RealtimeVoiceTrainingModel {
    nonisolated enum VoiceKind: String, Codable, CaseIterable {
        case allocated, custom
    }

    nonisolated enum Phase: Equatable {
        case idle, notFound, submitting, querying, training, ready, active, failed, rejected, outcomeUnknown
    }

    nonisolated struct Attempt: Codable, Equatable {
        let voiceKind: VoiceKind
        let voiceID: String
        let language: String
        let submittedAt: Date
        var requestID: String?
        var outcomeUnknown: Bool

        var voice: DoubaoVoiceServices.VoiceIdentifier {
            voiceKind == .allocated ? .allocated(voiceID) : .custom(voiceID)
        }
    }

    nonisolated struct Services: Sendable {
        var train: @Sendable (Data, String, DoubaoVoiceServices.VoiceIdentifier, String, String,
                              CredentialStore.DoubaoCredentials, String) async throws -> DoubaoVoiceServices.VoiceTrainingResult
        var query: @Sendable (DoubaoVoiceServices.VoiceIdentifier,
                              CredentialStore.DoubaoCredentials) async throws -> DoubaoVoiceServices.VoiceTrainingResult

        static let live = Services(train: { audio, format, voice, transcript, language, credentials, requestID in
            try await DoubaoVoiceServices.trainRealtimeVoice(
                audio, format: format, voice: voice, transcript: transcript,
                language: language, credentials: credentials, requestID: requestID
            )
        }, query: { voice, credentials in
            try await DoubaoVoiceServices.realtimeVoiceStatus(voice: voice, credentials: credentials)
        })
    }

    var voiceKind = VoiceKind.allocated
    var voiceID = ""
    var language = "zh"
    var transcript = ""
    private(set) var sampleName: String?
    private(set) var phase = Phase.idle
    private(set) var message: String?
    private(set) var requestID: String?
    private(set) var lastQueryRequestID: String?
    private(set) var logID: String?
    private(set) var result: DoubaoVoiceServices.VoiceTrainingResult?
    private(set) var pendingAttempt: Attempt?

    @ObservationIgnored private let services: Services
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let pendingKey: String
    @ObservationIgnored private var sample: Data?
    @ObservationIgnored private var sampleFormat = "wav"
    @ObservationIgnored private var resolvedVoice: DoubaoVoiceServices.VoiceIdentifier?

    init(services: Services = .live, defaults: UserDefaults = .standard,
         pendingKey: String = "realtimeVoiceTraining.pending.v1") {
        self.services = services
        self.defaults = defaults
        self.pendingKey = pendingKey
        if let encoded = defaults.data(forKey: pendingKey),
           let attempt = try? JSONDecoder().decode(Attempt.self, from: encoded) {
            pendingAttempt = attempt
            voiceKind = attempt.voiceKind
            voiceID = attempt.voiceID
            language = attempt.language
            requestID = attempt.requestID
            phase = attempt.outcomeUnknown ? .outcomeUnknown : .training
        }
    }

    var isBusy: Bool { phase == .submitting || phase == .querying }
    var requiresQuery: Bool { pendingAttempt != nil }
    var canSubmit: Bool { !isBusy && !requiresQuery && sample != nil && !voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var voice: DoubaoVoiceServices.VoiceIdentifier {
        let identifier = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        return voiceKind == .allocated ? .allocated(identifier) : .custom(identifier)
    }

    func clearSample() {
        guard !isBusy, !requiresQuery else { return }
        sample = nil
        sampleName = nil
    }

    func setSample(_ audio: Data, format: String, fileName: String) throws {
        guard !isBusy, !requiresQuery else { return }
        do {
            try DoubaoVoiceServices.validateRealtimeTrainingSample(audio, format: format, language: language)
            sample = audio
            sampleFormat = format.lowercased()
            sampleName = fileName
            message = nil
        } catch {
            sample = nil
            sampleName = nil
            phase = .rejected
            message = error.localizedDescription
            throw error
        }
    }

    func submit(credentials: CredentialStore.DoubaoCredentials, isCallRunning: Bool = false) async {
        guard !isCallRunning, !isBusy, !requiresQuery else { return }
        let selectedVoice = voice
        do {
            try DoubaoVoiceServices.validateRealtimeVoiceIdentifier(selectedVoice)
            guard let sample else { throw DoubaoVoiceServices.ServiceError(message: "Select a recording first") }
            try DoubaoVoiceServices.validateRealtimeTrainingSample(sample, format: sampleFormat, language: language)
            guard credentials.isComplete else { throw DoubaoVoiceServices.ServiceError(message: "Doubao speech credentials are missing") }

            // Unknown until an authoritative service response arrives. If the
            // process exits during this await, reopening offers only a query.
            let submissionID = UUID().uuidString
            let attempt = Attempt(voiceKind: voiceKind, voiceID: selectedVoice.effectiveSpeakerID,
                                  language: language, submittedAt: .now, requestID: submissionID,
                                  outcomeUnknown: true)
            pendingAttempt = attempt
            persistPending()
            phase = .submitting
            message = nil
            requestID = submissionID
            lastQueryRequestID = nil
            logID = nil
            result = nil
            resolvedVoice = nil
            do {
                let response = try await services.train(sample, sampleFormat, selectedVoice, transcript,
                                                        language, credentials, submissionID)
                receive(response, for: selectedVoice)
            } catch {
                receiveSubmissionError(error)
            }
        } catch {
            phase = .rejected
            message = error.localizedDescription
        }
    }

    func query(credentials: CredentialStore.DoubaoCredentials) async {
        guard !isBusy else { return }
        let selectedVoice = pendingAttempt?.voice ?? voice
        do {
            try DoubaoVoiceServices.validateRealtimeVoiceIdentifier(selectedVoice)
            guard credentials.isComplete else { throw DoubaoVoiceServices.ServiceError(message: "Doubao speech credentials are missing") }
            phase = .querying
            message = nil
            result = nil
            resolvedVoice = nil
            let response = try await services.query(selectedVoice, credentials)
            receive(response, for: selectedVoice)
        } catch {
            if let serviceError = error as? DoubaoVoiceServices.VoiceTrainingError {
                lastQueryRequestID = serviceError.requestID
                logID = serviceError.logID
            }
            phase = pendingAttempt == nil ? .rejected : .outcomeUnknown
            message = error.localizedDescription
            if pendingAttempt != nil {
                pendingAttempt?.outcomeUnknown = true
                persistPending()
            }
        }
    }

    /// Applying a voice is always an explicit UI action, and only applies
    /// the exact identity whose successful status was queried or returned.
    func usableVoiceID(isCallRunning: Bool = false) -> String? {
        guard !isCallRunning, !isBusy, pendingAttempt == nil,
              phase == .ready || phase == .active,
              resolvedVoice == voice, let result, result.status.isUsable,
              !result.speakerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return result.speakerID
    }

    private func receive(_ response: DoubaoVoiceServices.VoiceTrainingResult,
                         for selectedVoice: DoubaoVoiceServices.VoiceIdentifier) {
        result = response
        resolvedVoice = selectedVoice
        message = nil
        switch response.status {
        case .notFound: phase = .notFound
        case .training: phase = .training
        case .ready: phase = .ready
        case .failed: phase = .failed
        case .active: phase = .active
        }
        if response.status == .training {
            if pendingAttempt == nil {
                pendingAttempt = Attempt(voiceKind: voiceKind, voiceID: selectedVoice.effectiveSpeakerID,
                                         language: language, submittedAt: .now, outcomeUnknown: false)
            }
            pendingAttempt?.outcomeUnknown = false
        } else {
            pendingAttempt = nil
        }
        persistPending()
    }

    private func receiveSubmissionError(_ error: Error) {
        captureRequestID(error)
        message = error.localizedDescription
        if let serviceError = error as? DoubaoVoiceServices.VoiceTrainingError, !serviceError.outcomeUnknown {
            phase = .rejected
            pendingAttempt = nil
        } else {
            phase = .outcomeUnknown
            pendingAttempt?.outcomeUnknown = true
        }
        persistPending()
    }

    private func captureRequestID(_ error: Error) {
        if let identifier = (error as? DoubaoVoiceServices.VoiceTrainingError)?.requestID {
            requestID = identifier
            pendingAttempt?.requestID = identifier
        }
        logID = (error as? DoubaoVoiceServices.VoiceTrainingError)?.logID
    }

    private func persistPending() {
        if let pendingAttempt, let encoded = try? JSONEncoder().encode(pendingAttempt) {
            defaults.set(encoded, forKey: pendingKey)
        } else {
            defaults.removeObject(forKey: pendingKey)
        }
    }
}
