import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

/// The board's control for the call agent: what it is doing, the button to
/// take the call over or hand it back, and the material it works from.
struct AgentButton: View {
    @Bindable var model: SubtitleModel
    @State private var isPresented = false

    private var agent: CallAgent { model.agent }

    var body: some View {
        HStack(spacing: Theme.spacing8) {
            if agent.phase.isActive {
                Button(t("agent.takeOver"), systemImage: "hand.raised") { agent.takeOver() }
                    .buttonStyle(.glassProminent)
                    .help(t("agent.takeOver.help"))
                    .transition(.opacity)
            } else if agent.phase == .handedOver || isFailed {
                Button(t("agent.handBack"), systemImage: "sparkles") { agent.handBack() }
                    .buttonStyle(.glass)
                    .help(t("agent.handBack.help"))
                    .transition(.opacity)
            }
            Button {
                isPresented.toggle()
            } label: {
                Label(t("agent.title"), systemImage: model.agentEnabled ? "person.wave.2.fill" : "person.wave.2")
            }
            .buttonStyle(.glass)
            .help(statusText)
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                AgentPanel(model: model)
                    .frame(width: 460)
                    .frame(minHeight: 360, idealHeight: 520, maxHeight: 620)
            }
        }
        .animation(Theme.quick, value: agent.phase)
    }

    private var isFailed: Bool {
        if case .failed = agent.phase { return true }
        return false
    }

    private var statusText: String {
        AgentPanel.statusText(agent.phase, enabled: model.agentEnabled,
                              isConnecting: agent.isRealtimeConnecting)
    }
}

/// The agent's material and switches, shown from the board.
struct AgentPanel: View {
    @Bindable var model: SubtitleModel

    static func statusText(_ phase: CallAgent.Phase, enabled: Bool,
                           isConnecting: Bool = false) -> String {
        if isConnecting { return t("agent.status.connecting") }
        return switch phase {
        case .off: t(enabled ? "agent.status.armed" : "agent.status.off")
        case .listening: t("agent.status.listening")
        case .thinking: t("agent.status.thinking")
        case .speaking: t("agent.status.speaking")
        case .handedOver: t("agent.status.handedOver")
        case .failed(let message): t("agent.status.failed", message)
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle(t("agent.enabled"), isOn: $model.agentEnabled)
                    .disabled(model.isRunning)
                Picker(t("agent.backend"), selection: $model.agentBackend) {
                    Text(t("agent.backend.doubaoRealtime")).tag(CallAgent.Backend.doubaoRealtime)
                    Text(t("agent.backend.chatAndTTS")).tag(CallAgent.Backend.chatAndTTS)
                }
                .disabled(model.isRunning)
                LabeledContent(t("agent.status"),
                               value: Self.statusText(model.agent.phase, enabled: model.agentEnabled,
                                                      isConnecting: model.agent.isRealtimeConnecting))
                if model.agent.phase == .listening && !model.agent.isRealtimeConnecting {
                    Button(t("agent.speakFirst"), systemImage: "phone.arrow.up.right") {
                        model.agent.speakFirst()
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(t(model.agentBackend == .doubaoRealtime
                           ? "agent.footer.doubaoRealtime" : "agent.footer"))
                    if model.agentBackend == .doubaoRealtime {
                        Text(t("agent.realtime.subtitleNotice"))
                    }
                }
                .font(.App.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                TextField(t("agent.goal.placeholder"), text: $model.agentGoal, axis: .vertical)
                    .lineLimit(1...3)
            } header: {
                Text(t("agent.goal"))
            }

            Section {
                TextEditor(text: $model.agentMaterials)
                    .font(.App.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 160)
                    .accessibilityLabel(t("agent.materials"))
            } header: {
                Text(t("agent.materials"))
            } footer: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(t("agent.materials.footer"))
                    if model.agentBackend == .doubaoRealtime {
                        Text(t("agent.realtime.briefNotice"))
                    }
                }
                .font(.App.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings › AI agent: only the selected backend's configuration.
struct AgentSettings: View {
    @Bindable var model: SubtitleModel
    @State private var chat = CredentialStore.AgentCredentials()
    @State private var speech = CredentialStore.DoubaoCredentials(appID: "", accessToken: "")
    @State private var isBusy = true
    @State private var saveResult: Bool?
    @State private var isImporting = false
    @State private var cloneMessage: String?
    @State private var isCloning = false
    @State private var sampleTranscript = ""
    @State private var realtimeTraining = RealtimeVoiceTrainingModel()
    @State private var isImportingRealtime = false
    @State private var realtimeImportError: String?
    @State private var realtimeSampleDuration: Double?
    @State private var isLoadingRealtimeSample = false

    var body: some View {
        Form {
            Section {
                Picker(t("agent.backend"), selection: $model.agentBackend) {
                    Text(t("agent.backend.doubaoRealtime")).tag(CallAgent.Backend.doubaoRealtime)
                    Text(t("agent.backend.chatAndTTS")).tag(CallAgent.Backend.chatAndTTS)
                }
                .disabled(model.isRunning)
                if model.agentBackend == .doubaoRealtime {
                    TextField(t("agent.realtime.voice"), text: $model.agentRealtimeVoice,
                              prompt: Text(DoubaoRealtimeClient.defaultVoice))
                        .autocorrectionDisabled()
                        .disabled(model.isRunning)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(t(model.agentBackend == .doubaoRealtime
                           ? "agent.settings.doubaoRealtime.footer" : "agent.settings.backend.footer"))
                    if model.agentBackend == .doubaoRealtime {
                        Text(t("agent.realtime.subtitleNotice"))
                    }
                }
                .font(.App.caption)
                .foregroundStyle(.secondary)
            }

            if model.agentBackend == .doubaoRealtime {
                realtimeTrainingSection
            }

            if model.agentBackend == .chatAndTTS {
                Section {
                    TextField(t("agent.chat.baseURL"), text: $chat.baseURL)
                        .autocorrectionDisabled()
                    SecureField(t("agent.chat.apiKey"), text: $chat.apiKey)
                    TextField(t("agent.chat.model"), text: $chat.model)
                        .autocorrectionDisabled()
                } header: {
                    Text(t("agent.chat.section"))
                } footer: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(t("agent.chat.footer"))
                        Link(t("agent.chat.console"),
                             destination: URL(string: "https://console.volcengine.com/ark")!)
                    }
                    .font(.App.caption)
                    .foregroundStyle(.secondary)
                }

                Section {
                    TextField(t("agent.voice.speakerID"), text: $speech.cloneSpeakerID)
                        .autocorrectionDisabled()
                    TextField(t("agent.voice.transcript"), text: $sampleTranscript, axis: .vertical)
                        .lineLimit(1...3)
                    HStack(spacing: Theme.spacing12) {
                        Button(t("agent.voice.upload"), systemImage: "waveform.badge.plus") {
                            isImporting = true
                        }
                        .disabled(!canManageVoice)
                        Button(t("agent.voice.check"), systemImage: "arrow.clockwise") { checkVoice() }
                            .disabled(!canManageVoice)
                        if isCloning { ProgressView().controlSize(.small) }
                    }
                    if speech.isComplete && speech.appID.isEmpty {
                        Text(t("agent.voice.needsAppID")).font(.App.caption).foregroundStyle(.secondary)
                    }
                    if let cloneMessage {
                        Text(cloneMessage).font(.App.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text(t("agent.voice.section"))
                } footer: {
                    Text(t("agent.voice.footer"))
                        .font(.App.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    HStack(spacing: Theme.spacing12) {
                        Button(t("settings.credentials.save")) { save() }
                            .buttonStyle(.borderedProminent)
                        Spacer()
                        if isBusy {
                            ProgressView().controlSize(.small)
                        } else if let saveResult {
                            Label(t(saveResult ? "settings.credentials.saved" : "settings.credentials.failed"),
                                  systemImage: saveResult ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(saveResult ? Theme.live : Theme.failure)
                                .font(.App.body)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(isBusy)
        .onAppear(perform: reload)
        .onChange(of: model.agentBackend) { reload() }
        .onChange(of: chat) { saveResult = nil }
        .onChange(of: speech) { saveResult = nil }
        .fileImporter(isPresented: $isImporting,
                      allowedContentTypes: Self.sampleTypes) { result in
            if case .success(let url) = result { upload(url) }
        }
        .fileImporter(isPresented: $isImportingRealtime,
                      allowedContentTypes: Self.realtimeSampleTypes) { result in
            switch result {
            case .success(let url): importRealtimeSample(url)
            case .failure(let error): realtimeImportError = error.localizedDescription
            }
        }
    }

    private var realtimeTrainingSection: some View {
        Section {
            Group {
                Picker(t("agent.realtime.training.kind"), selection: $realtimeTraining.voiceKind) {
                    Text(t("agent.realtime.training.allocated")).tag(RealtimeVoiceTrainingModel.VoiceKind.allocated)
                    Text(t("agent.realtime.training.custom")).tag(RealtimeVoiceTrainingModel.VoiceKind.custom)
                }
                TextField(t(realtimeTraining.voiceKind == .allocated
                            ? "agent.voice.speakerID" : "agent.realtime.training.customID"),
                          text: $realtimeTraining.voiceID)
                    .autocorrectionDisabled()
                Picker(t("agent.realtime.training.language"), selection: $realtimeTraining.language) {
                    Text(t("agent.realtime.training.zh")).tag("zh")
                    Text(t("agent.realtime.training.en")).tag("en")
                }
                TextField(t("agent.voice.transcript"), text: $realtimeTraining.transcript, axis: .vertical)
                    .lineLimit(1...3)
            }
            .disabled(model.isRunning || realtimeTraining.isBusy || realtimeTraining.requiresQuery)

            HStack(spacing: Theme.spacing12) {
                Button(t("agent.realtime.training.select"), systemImage: "doc.badge.plus") {
                    isImportingRealtime = true
                }
                .disabled(model.isRunning || isLoadingRealtimeSample || realtimeTraining.isBusy || realtimeTraining.requiresQuery)
                Button(t("agent.realtime.training.submit"), systemImage: "arrow.up.doc") {
                    Task { await realtimeTraining.submit(credentials: speech, isCallRunning: model.isRunning) }
                }
                .disabled(model.isRunning || isLoadingRealtimeSample || !realtimeTraining.canSubmit || !speech.isComplete)
                if realtimeTraining.isBusy { ProgressView().controlSize(.small) }
            }
            if let name = realtimeTraining.sampleName {
                Text(name).font(.App.caption).foregroundStyle(.secondary)
                if let duration = realtimeSampleDuration {
                    Text(t("agent.realtime.training.duration", String(format: "%.1f", duration)))
                        .font(.App.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: Theme.spacing12) {
                Button(t("agent.voice.check"), systemImage: "arrow.clockwise") {
                    Task { await realtimeTraining.query(credentials: speech) }
                }
                .disabled(realtimeTraining.isBusy || realtimeTraining.voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || !speech.isComplete)
                Button(t("agent.realtime.training.apply"), systemImage: "person.wave.2") {
                    if let speakerID = realtimeTraining.usableVoiceID(isCallRunning: model.isRunning) {
                        model.agentRealtimeVoice = speakerID
                    }
                }
                .disabled(realtimeTraining.usableVoiceID(isCallRunning: model.isRunning) == nil)
            }

            if model.isRunning {
                Text(t("agent.realtime.training.callRunning")).font(.App.caption).foregroundStyle(.secondary)
            }
            if !speech.isComplete {
                Text(t("agent.realtime.training.credentials")).font(.App.caption).foregroundStyle(.secondary)
            }
            Text(realtimeTrainingStatus).font(.App.caption).foregroundStyle(.secondary)
            if let result = realtimeTraining.result {
                LabeledContent(t("agent.realtime.training.returnedID"), value: result.speakerID)
                    .font(.App.caption).textSelection(.enabled)
                if let remaining = result.remainingTrainingTimes {
                    LabeledContent(t("agent.realtime.training.remaining"), value: String(remaining))
                        .font(.App.caption)
                }
            }
            if let message = realtimeTraining.message {
                Text(message).font(.App.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let requestID = realtimeTraining.requestID {
                LabeledContent(t("agent.realtime.training.requestID"), value: requestID)
                    .font(.App.caption).textSelection(.enabled)
            }
            if let requestID = realtimeTraining.lastQueryRequestID {
                LabeledContent(t("agent.realtime.training.queryRequestID"), value: requestID)
                    .font(.App.caption).textSelection(.enabled)
            }
            if let logID = realtimeTraining.logID {
                LabeledContent("Log ID", value: logID)
                    .font(.App.caption).textSelection(.enabled)
            }
            if let realtimeImportError {
                Text(realtimeImportError).font(.App.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text(t("agent.realtime.training.section"))
        } footer: {
            VStack(alignment: .leading, spacing: 5) {
                Text(t("agent.realtime.training.footer"))
                if realtimeTraining.voiceKind == .custom {
                    Text(t("agent.realtime.training.postpaid"))
                } else {
                    Text(t("agent.realtime.training.prepaid"))
                }
                if realtimeTraining.requiresQuery {
                    Text(t("agent.realtime.training.queryRequired"))
                }
            }
            .font(.App.caption).foregroundStyle(.secondary)
        }
    }

    private var realtimeTrainingStatus: String {
        switch realtimeTraining.phase {
        case .idle: t("agent.realtime.training.status.idle")
        case .notFound: t("agent.realtime.training.notFound")
        case .submitting: t("agent.realtime.training.status.submitting")
        case .querying: t("agent.realtime.training.status.querying")
        case .training: t("agent.realtime.training.status.training")
        case .ready: t("agent.realtime.training.status.ready")
        case .active: t("agent.realtime.training.status.active")
        case .failed: t("agent.realtime.training.status.failed")
        case .rejected: t("agent.realtime.training.status.rejected")
        case .outcomeUnknown: t("agent.realtime.training.status.unknown")
        }
    }

    /// The v1 cloning endpoints this tab calls take the App ID and token
    /// login only; a console API key trains voices on the console instead.
    private var canManageVoice: Bool {
        !speech.cloneSpeakerID.isEmpty && speech.isComplete && !speech.appID.isEmpty && !isCloning
    }

    /// What the v1 cloning endpoint takes, and nothing else the picker
    /// would otherwise offer (AIFF, CAF, FLAC) only to have it refused.
    private static let sampleTypes: [UTType] =
        [.wav, .mp3, .mpeg4Audio] + ["ogg", "aac"].compactMap { UTType(filenameExtension: $0) }

    private static let realtimeSampleTypes: [UTType] =
        sampleTypes + [UTType(filenameExtension: "pcm") ?? .data]

    private func importRealtimeSample(_ url: URL) {
        guard !model.isRunning, !isLoadingRealtimeSample,
              !realtimeTraining.isBusy, !realtimeTraining.requiresQuery else { return }
        realtimeTraining.clearSample()
        realtimeImportError = nil
        realtimeSampleDuration = nil
        isLoadingRealtimeSample = true
        Task {
            defer { isLoadingRealtimeSample = false }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let byteCount = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard byteCount <= DoubaoVoiceServices.maximumRealtimeTrainingBytes else {
                    throw DoubaoVoiceServices.ServiceError(message: t("agent.realtime.training.tooLarge"))
                }
                let audio = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: url)
                }.value
                let format = url.pathExtension.lowercased()
                guard !model.isRunning else { return }
                try realtimeTraining.setSample(audio, format: format, fileName: url.lastPathComponent)
                if format == "pcm" {
                    realtimeSampleDuration = Double(audio.count) / (24_000 * 2)
                } else {
                    let asset = AVURLAsset(url: url)
                    if let duration = try? await asset.load(.duration), duration.seconds.isFinite {
                        realtimeSampleDuration = duration.seconds
                    }
                }
            } catch {
                realtimeImportError = error.localizedDescription
            }
        }
    }

    private func reload() {
        let needsChat = model.agentBackend == .chatAndTTS
        isBusy = true
        Task {
            defer { isBusy = false }
            let stored = await Task.detached(priority: .userInitiated) {
                (needsChat ? CredentialStore.loadAgent() : CredentialStore.AgentCredentials(), CredentialStore.loadDoubao())
            }.value
            chat = stored.0
            speech = stored.1
            saveResult = nil
        }
    }

    private func save() {
        var chat = chat
        chat.baseURL = chat.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        chat.apiKey = chat.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        chat.model = chat.model.trimmingCharacters(in: .whitespacesAndNewlines)
        var speech = speech
        speech.cloneSpeakerID = speech.cloneSpeakerID.trimmingCharacters(in: .whitespacesAndNewlines)
        isBusy = true
        Task {
            defer { isBusy = false }
            saveResult = await Task.detached(priority: .userInitiated) {
                // The Doubao item is shared with the credentials tab; only
                // the trained voice is edited here.
                var stored = CredentialStore.loadDoubao()
                stored.cloneSpeakerID = speech.cloneSpeakerID
                return CredentialStore.saveAgent(chat) && CredentialStore.saveDoubao(stored)
            }.value
        }
    }

    private func upload(_ url: URL) {
        let speech = speech
        let transcript = sampleTranscript
        // The sample is the user speaking their own language.
        let language = SubtitleModel.savedMyLanguage
        isCloning = true
        cloneMessage = t("agent.voice.uploading")
        Task {
            defer { isCloning = false }
            do {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let format = url.pathExtension.lowercased() == "m4a" ? "m4a" : url.pathExtension.lowercased()
                try await DoubaoVoiceServices.uploadSample(
                    data, format: format.isEmpty ? "wav" : format,
                    speakerID: speech.cloneSpeakerID, transcript: transcript,
                    language: language, credentials: speech
                )
                cloneMessage = t("agent.voice.uploaded")
            } catch {
                cloneMessage = t("agent.voice.error", error.localizedDescription)
            }
        }
    }

    private func checkVoice() {
        let speech = speech
        isCloning = true
        Task {
            defer { isCloning = false }
            do {
                let status = try await DoubaoVoiceServices.cloneStatus(
                    speakerID: speech.cloneSpeakerID, credentials: speech
                )
                cloneMessage = t("agent.voice.status.\(status)")
            } catch {
                cloneMessage = t("agent.voice.error", error.localizedDescription)
            }
        }
    }
}
