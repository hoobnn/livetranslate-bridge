import SwiftUI

/// Persistent, low-frequency preferences. Session controls live on the
/// subtitle board, where they can be changed without opening Settings.
struct SettingsView: View {
    @Bindable var model: SubtitleModel
    @Bindable var localization: LocalizationStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TabView {
            Tab(t("settings.tab.general"), systemImage: "gearshape") {
                GeneralSettings(model: model, localization: localization)
            }
            Tab(t("settings.tab.credentials"), systemImage: "key") {
                CredentialSettings()
            }
            Tab(t("settings.tab.voice"), systemImage: "speaker.wave.2") {
                AudioRoutingSettings(model: model)
            }
            Tab(t("settings.tab.translation"), systemImage: "character.bubble") {
                TranslationSettings(model: model)
            }
        }
        .frame(width: 580, height: 560)
        .scenePadding(.top)
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
    }
}

// MARK: - general

private struct GeneralSettings: View {
    @Bindable var model: SubtitleModel
    @Bindable var localization: LocalizationStore
    @State private var confirmsDeleteAll = false

    var body: some View {
        Form {
            Section {
                Picker(t("settings.general.language"),
                       selection: $localization.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.endonym).tag(language)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text(t("settings.general.appearance"))
            } footer: {
                Text(t("settings.general.language.footer"))
                    .font(.App.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(t("settings.history.save"), isOn: $model.savesHistory)
                Toggle(t("settings.history.recording"), isOn: $model.savesRecording)
                    .disabled(!model.savesHistory)
                HStack(spacing: Theme.spacing12) {
                    Button(t("settings.history.reveal")) { revealHistory() }
                        .disabled(model.history.directory == nil)
                    Button(t("settings.history.deleteAll"), role: .destructive) {
                        confirmsDeleteAll = true
                    }
                    .disabled(model.history.records.isEmpty)
                }
            } header: {
                Text(t("settings.history.section"))
            } footer: {
                Text(t("settings.history.footer"))
                    .font(.App.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(t("settings.history.deleteAll.title"),
                            isPresented: $confirmsDeleteAll,
                            titleVisibility: .visible) {
            Button(t("settings.history.deleteAll"), role: .destructive) {
                // The session still being written would only be saved again
                // by the next autosave, so it is the one thing left in place.
                model.history.deleteAll(except: model.isRunning ? model.liveSessionID : nil)
            }
        } message: {
            Text(t("settings.history.deleteAll.message"))
        }
    }

    private func revealHistory() {
        guard let directory = model.history.directory else { return }
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }
}

// MARK: - credentials

private struct CredentialSettings: View {
    @State private var apiKey = ""
    @State private var workspaceID = ""
    @State private var saveResult: SaveResult?
    @State private var isBusy = true
    @State private var confirmsClear = false

    private enum SaveResult: Equatable {
        case saved
        case failed
        case cleared
    }

    var body: some View {
        Form {
            Section {
                SecureField(t("settings.credentials.apiKey"), text: Binding(
                    get: { apiKey }, set: { apiKey = $0; saveResult = nil }
                ))
                TextField(t("settings.credentials.workspaceID"), text: Binding(
                    get: { workspaceID }, set: { workspaceID = $0; saveResult = nil }
                ))
                    .autocorrectionDisabled()
            } header: {
                Text(t("settings.credentials.section"))
            } footer: {
                VStack(alignment: .leading, spacing: 5) {
                    Label(t("settings.credentials.footer.keychain"),
                          systemImage: "lock.shield")
                    Text(t("settings.credentials.footer.workspace"))
                    Link(t("settings.credentials.console"),
                         destination: URL(string: "https://bailian.console.aliyun.com/")!)
                }
                .font(.App.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: Theme.spacing12) {
                    Button(t("settings.credentials.save")) { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(t("settings.credentials.clear"), role: .destructive) {
                        confirmsClear = true
                    }
                    .disabled(apiKey.isEmpty && workspaceID.isEmpty)

                    Spacer()

                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else if let saveResult {
                        resultLabel(saveResult)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .animation(Theme.quick, value: saveResult)
            }
        }
        .formStyle(.grouped)
        .disabled(isBusy)
        .onAppear(perform: reload)
        .confirmationDialog(t("ux.credentials.clear.title"), isPresented: $confirmsClear,
                            titleVisibility: .visible) {
            Button(t("settings.credentials.clear"), role: .destructive) { clear() }
        } message: {
            Text(t("ux.credentials.clear.message"))
        }
    }

    @ViewBuilder
    private func resultLabel(_ result: SaveResult) -> some View {
        switch result {
        case .saved:
            Label(t("settings.credentials.saved"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.live).font(.App.body)
        case .cleared:
            Label(t("settings.credentials.cleared"), systemImage: "trash")
                .foregroundStyle(.secondary).font(.App.body)
        case .failed:
            Label(t("settings.credentials.failed"), systemImage: "xmark.circle.fill")
                .foregroundStyle(Theme.failure).font(.App.body)
        }
    }

    private func reload() {
        isBusy = true
        Task {
            defer { isBusy = false }
            let stored = await Task.detached(priority: .userInitiated) {
                CredentialStore.load()
            }.value
            apiKey = stored.apiKey
            workspaceID = stored.workspaceID
        }
    }

    private func save() {
        let credentials = CredentialStore.Credentials(
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            workspaceID: workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        isBusy = true
        Task {
            defer { isBusy = false }
            let ok = await Task.detached(priority: .userInitiated) {
                CredentialStore.save(credentials)
            }.value
            saveResult = ok ? .saved : .failed
        }
    }

    private func clear() {
        isBusy = true
        Task {
            defer { isBusy = false }
            let ok = await Task.detached(priority: .userInitiated) {
                CredentialStore.clear()
            }.value
            if ok {
                apiKey = ""
                workspaceID = ""
            }
            saveResult = ok ? .cleared : .failed
        }
    }
}

// MARK: - translation

private struct TranslationSettings: View {
    @Bindable var model: SubtitleModel

    var body: some View {
        Form {
            Section {
                Picker(t("settings.translation.region"), selection: $model.region) {
                    Text(t("settings.translation.region.beijing"))
                        .tag(TranslationClient.Config.Region.beijing)
                    Text(t("settings.translation.region.singapore"))
                        .tag(TranslationClient.Config.Region.singapore)
                }
            } header: {
                Text(t("settings.translation.section"))
            } footer: {
                Text(t("settings.translation.footer"))
                    .font(.App.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(model.isRunning)

            SegmentationSettings(model: model)

            Section {
                TextEditor(text: $model.glossaryText)
                    .font(.App.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 88)
                    .accessibilityLabel(t("settings.glossary.section"))
            } header: {
                Text(t("settings.glossary.section"))
            } footer: {
                Text(t("settings.glossary.footer"))
                    .font(.App.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(model.isRunning)

            Section {
                Toggle(t("settings.upload.microphoneGate"), isOn: $model.gatesMicrophoneSilence)
            } header: {
                Text(t("settings.upload.section"))
            } footer: {
                Text(t("settings.upload.footer"))
                    .font(.App.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(model.isRunning)
        }
        .formStyle(.grouped)
    }
}

// MARK: - segmentation

/// qwen3.8 owns segmentation; old VAD preferences are not active controls.
private struct SegmentationSettings: View {
    @Bindable var model: SubtitleModel

    var body: some View {
        Section {
            Text(t("settings.segmentation.models"))
                .font(.App.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text(t("settings.segmentation.section"))
        }
    }
}
