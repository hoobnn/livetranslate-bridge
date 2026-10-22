import SwiftUI
import UniformTypeIdentifiers

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

    private var statusText: String { AgentPanel.statusText(agent.phase, enabled: model.agentEnabled) }
}

/// The agent's material and switches, shown from the board.
struct AgentPanel: View {
    @Bindable var model: SubtitleModel

    static func statusText(_ phase: CallAgent.Phase, enabled: Bool) -> String {
        switch phase {
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
                LabeledContent(t("agent.status"),
                               value: Self.statusText(model.agent.phase, enabled: model.agentEnabled))
                if model.agent.phase == .listening {
                    Button(t("agent.speakFirst"), systemImage: "phone.arrow.up.right") {
                        model.agent.speakFirst()
                    }
                }
            } footer: {
                Text(t("agent.footer"))
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
                Text(t("agent.materials.footer"))
                    .font(.App.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings › AI agent: the chat model and the user's trained voice.
struct AgentSettings: View {
    @State private var chat = CredentialStore.AgentCredentials()
    @State private var speech = CredentialStore.DoubaoCredentials(appID: "", accessToken: "")
    @State private var isBusy = true
    @State private var saveResult: Bool?
    @State private var isImporting = false
    @State private var cloneMessage: String?
    @State private var isCloning = false
    @State private var sampleTranscript = ""

    var body: some View {
        Form {
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
        .formStyle(.grouped)
        .disabled(isBusy)
        .onAppear(perform: reload)
        .onChange(of: chat) { saveResult = nil }
        .onChange(of: speech) { saveResult = nil }
        .fileImporter(isPresented: $isImporting,
                      allowedContentTypes: Self.sampleTypes) { result in
            if case .success(let url) = result { upload(url) }
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

    private func reload() {
        isBusy = true
        Task {
            defer { isBusy = false }
            let stored = await Task.detached(priority: .userInitiated) {
                (CredentialStore.loadAgent(), CredentialStore.loadDoubao())
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
