import SwiftUI

/// Persistent, low-frequency preferences. Session controls live on the
/// subtitle board, where they can be changed without opening Settings.
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
            Tab(t("settings.tab.translation"), systemImage: "character.bubble") {
                TranslationSettings(model: model)
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
        Task {
            let stored = await Task.detached(priority: .userInitiated) {
                CredentialStore.load()
            }.value
            apiKey = stored.apiKey
            workspaceID = stored.workspaceID
        }
    }

    private func save() {
        let credentials = CredentialStore.Credentials(
            apiKey: apiKey, workspaceID: workspaceID
        )
        Task {
            let ok = await Task.detached(priority: .userInitiated) {
                CredentialStore.save(credentials)
            }.value
            saveResult = ok ? .saved : .failed
        }
    }

    private func clear() {
        apiKey = ""
        workspaceID = ""
        Task {
            let ok = await Task.detached(priority: .userInitiated) {
                CredentialStore.clear()
            }.value
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(model.isRunning)
        }
        .formStyle(.grouped)
    }
}
