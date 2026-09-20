import SwiftUI

/// Credentials and translation options. The CLI took these from `.env` and
/// command-line flags; a bundled app has neither, so they live here and in the
/// keychain.
///
/// Split into tabs the way macOS settings windows are: one screenful each,
/// rather than one long form the user has to scroll to find the API key in.
struct SettingsView: View {
    @Bindable var model: SubtitleModel
    @Bindable var localization: LocalizationStore

    var body: some View {
        TabView {
            Tab(t("settings.tab.general"), systemImage: "gearshape") {
                GeneralSettings(localization: localization)
            }
            Tab(t("settings.tab.credentials"), systemImage: "key") {
                CredentialSettings()
            }
            Tab(t("settings.tab.display"), systemImage: "textformat.size") {
                DisplaySettings(model: model)
            }
            Tab(t("settings.tab.translation"), systemImage: "character.bubble") {
                TranslationSettings(model: model)
            }
            Tab(t("settings.tab.voice"), systemImage: "speaker.wave.2") {
                VoiceSettings(model: model)
            }
        }
        .frame(width: 520)
        .scenePadding(.top)
    }
}

// MARK: - general

private struct GeneralSettings: View {
    @Bindable var localization: LocalizationStore

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
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - display

/// How the subtitle board is drawn. The same three settings as the board's own
/// Display menu, which is where they are reached mid-call; here they read as
/// prose with room to say what each one does, and the size picker can show its
/// options at their own sizes rather than as four words in a menu.
private struct DisplaySettings: View {
    @Bindable var model: SubtitleModel

    var body: some View {
        Form {
            Section {
                Picker(t("display.size"), selection: $model.transcriptSize) {
                    ForEach(SubtitleModel.TranscriptSize.allCases) { size in
                        // Each option set in the size it selects: the choice
                        // is about legibility, so it should be legible from
                        // the row rather than inferred from the word.
                        Text(size.label)
                            .font(.system(size: min(size.primary, 20)))
                            .tag(size)
                    }
                }

                Toggle(t("display.timestamps"), isOn: $model.showsTimestamps)

                Toggle(t("display.sourceText"), isOn: $model.showsSourceText)
                    .disabled(model.runningMode == .transcribe)
            } header: {
                Text(t("settings.display.section"))
            } footer: {
                Text(t("settings.display.footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - credentials

private struct CredentialSettings: View {
    @State private var apiKey = ""
    @State private var workspaceID = ""
    @State private var saveResult: SaveResult?

    private enum SaveResult: Equatable {
        case saved
        case failed
        case cleared
    }

    var body: some View {
        Form {
            Section {
                SecureField(t("settings.credentials.apiKey"), text: $apiKey)
                TextField(t("settings.credentials.workspaceID"), text: $workspaceID)
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
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 10) {
                    Button(t("settings.credentials.save")) { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(apiKey.isEmpty || workspaceID.isEmpty)
                    Button(t("settings.credentials.clear"), role: .destructive) {
                        clear()
                    }
                    .disabled(apiKey.isEmpty && workspaceID.isEmpty)

                    Spacer()

                    if let saveResult {
                        resultLabel(saveResult)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .animation(.snappy(duration: 0.2), value: saveResult)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
    }

    @ViewBuilder
    private func resultLabel(_ result: SaveResult) -> some View {
        switch result {
        case .saved:
            Label(t("settings.credentials.saved"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout)
        case .cleared:
            Label(t("settings.credentials.cleared"), systemImage: "trash")
                .foregroundStyle(.secondary).font(.callout)
        case .failed:
            Label(t("settings.credentials.failed"), systemImage: "xmark.circle.fill")
                .foregroundStyle(.red).font(.callout)
        }
    }

    private func reload() {
        let stored = CredentialStore.load()
        apiKey = stored.apiKey
        workspaceID = stored.workspaceID
    }

    private func save() {
        let ok = CredentialStore.save(
            CredentialStore.Credentials(apiKey: apiKey, workspaceID: workspaceID)
        )
        saveResult = ok ? .saved : .failed
    }

    private func clear() {
        CredentialStore.clear()
        apiKey = ""
        workspaceID = ""
        saveResult = .cleared
    }
}

// MARK: - translation

private struct TranslationSettings: View {
    @Bindable var model: SubtitleModel

    var body: some View {
        Form {
            Section {
                // The language pair lives in the subtitle header, where it is
                // set before every call; duplicating it here would give the
                // same setting two homes and no clear owner.
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(model.isRunning)

            // The pair itself is set in the subtitle header, where it is
            // chosen before every call — duplicating the two menus here would
            // give one setting two homes. What belongs here is the escape
            // hatch: a pair stored wrong by an earlier build cannot always be
            // corrected one menu at a time, because picking the language the
            // other side holds swaps them instead.
            Section {
                LabeledContent(t("settings.translation.languages")) {
                    Text(t("settings.translation.languages.current",
                           Language.named(model.myLanguage)?.menuLabel
                             ?? model.myLanguage,
                           Language.named(model.theirLanguage)?.menuLabel
                             ?? model.theirLanguage))
                        .foregroundStyle(.secondary)
                }

                Button(t("settings.translation.languages.reset"),
                       systemImage: "arrow.counterclockwise") {
                    model.resetLanguagesToDefault()
                }
                .controlSize(.small)
                .disabled(model.isRunning || model.usesDefaultLanguagePair)
            } footer: {
                Text(t("settings.translation.languages.footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - voice output

/// Where our own translation is spoken, and in whose voice.
///
/// Both directions always run, so there is nothing here to switch on — this
/// pane only answers where the synthesised speech goes. The app can play it
/// into any output device, but only the user can make the far end *hear* it:
/// Continuity relay reads our side of the call from the system default input,
/// so the translation reaches the call only when it is played into a loopback
/// device that is also selected as that input. The app says so and shows what
/// the current default input is; it cannot set it, and it cannot install the
/// device.
private struct VoiceSettings: View {
    @Bindable var model: SubtitleModel

    @State private var devices: [AudioOutputDevice] = []
    @State private var inputs: [AudioInputDevice] = []
    @State private var defaultInputName: String?

    /// The configuration that silently breaks the call: the chosen capture
    /// device also has output streams, so it is a loopback — and if we are
    /// speaking into one, this capture hears our own translation and
    /// translates it again. Following the system default is the same trap
    /// whenever that default is the loopback the user wired into the call.
    private var feedbackRisk: Bool {
        guard model.speaksTranslation else { return false }
        guard let chosen = inputs.first(where: { $0.uid == model.inputDeviceUID })
        else { return true }
        return chosen.hasOutputStreams
    }

    var body: some View {
        Form {
            Section {
                // Two ways the controls below can be inert: nothing is
                // synthesised while transcribing, and nothing of ours is
                // captured to synthesise when only the far end is. Said once
                // here rather than leaving the user to work out why picking a
                // device changes nothing.
                if model.mode == .transcribe {
                    Label(t("settings.voice.transcribe"),
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.scope == .remoteOnly {
                    Label(t("settings.voice.remoteOnly"),
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Choosing a device *is* switching speech on, so there is no
                // separate toggle to contradict it. "Off" is the empty choice.
                Picker(t("settings.voice.device"), selection: $model.outputDeviceUID) {
                    Text(t("settings.voice.device.off")).tag("")
                    Divider()
                    ForEach(devices) { device in
                        // The loopback marker is the whole point of the menu:
                        // it says which entries can actually reach the call.
                        Text(device.hasInputStreams
                             ? "\(device.name)  ·  \(t("settings.voice.device.loopback"))"
                             : device.name)
                            .tag(device.uid ?? "")
                    }
                }
                .disabled(model.isRunning)

                // Capturing us is the other half of the wiring: the output
                // above may hand the default input to a loopback, so the
                // microphone has to be named rather than inferred.
                Picker(t("settings.voice.input"), selection: $model.inputDeviceUID) {
                    Text(t("settings.voice.input.default")).tag("")
                    Divider()
                    ForEach(inputs) { device in
                        Text(device.hasOutputStreams
                             ? "\(device.name)  ·  \(t("settings.voice.input.loopback"))"
                             : device.name)
                            .tag(device.uid ?? "")
                    }
                }
                .disabled(model.isRunning)

                if feedbackRisk {
                    Label(t("settings.voice.input.warning"),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Toggle(t("settings.voice.clone"), isOn: $model.clonesVoice)
                    .disabled(model.isRunning || !model.speaksTranslation)

                LabeledContent(t("settings.voice.currentInput")) {
                    Text(defaultInputName ?? t("settings.voice.currentInput.unknown"))
                        .foregroundStyle(.secondary)
                }

                Button(t("settings.voice.refresh"), systemImage: "arrow.clockwise") {
                    reload()
                }
                .controlSize(.small)
            } header: {
                Text(t("settings.voice.section"))
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(t("settings.voice.footer"))
                    Text(t("settings.voice.clone.footer"))
                    Label(t("settings.voice.howto"), systemImage: "arrow.triangle.branch")
                    Link(t("settings.voice.blackhole"),
                         destination: URL(string: "https://existential.audio/blackhole/")!)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
    }

    private func reload() {
        devices = AudioOutputDevice.outputs()
        inputs = AudioInputDevice.inputs()
        defaultInputName = AudioOutputDevice.systemDefaultInputName
    }
}
