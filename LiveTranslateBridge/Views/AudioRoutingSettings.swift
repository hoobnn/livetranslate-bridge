import SwiftUI

/// High-frequency audio choices shown beside the session controls.
struct AudioRoutingSettings: View {
    @Bindable var model: SubtitleModel

    @State private var outputs: [AudioOutputDevice] = []
    @State private var inputs: [AudioInputDevice] = []
    @State private var sources: [AudioSourceApplication] = []
    @State private var isReloading = false
    @State private var defaultOutputName: String?

    private var feedbackRisk: Bool {
        guard model.speaksTranslation else { return false }
        guard let chosen = inputs.first(where: { $0.uid == model.inputDeviceUID })
        else { return true }
        return chosen.hasOutputStreams
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(t("settings.tab.voice"))
                    .font(.App.title)
                Spacer()
                Button(t("settings.voice.refresh"), systemImage: "arrow.clockwise") {
                    reload()
                }
                .controlSize(.small)
                .disabled(isReloading)
                if isReloading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, Theme.spacing20)
            .padding(.vertical, Theme.spacing12)

            Divider()

            Form {
                if model.isRunning {
                    Section {
                        Label(t("ux.audio.locked"), systemImage: "lock")
                            .font(.App.caption).foregroundStyle(.secondary)
                    }
                }
                if model.scope != .localOnly { sourceSection }
                if model.scope != .remoteOnly { inputSection }
                if model.scope != .localOnly { incomingSection }
                if model.scope != .remoteOnly { outgoingSection }
                if model.mode == .translate { voiceCloneSection }
            }
            .formStyle(.grouped)
        }
        .onAppear(perform: reload)
    }

    private var sourceSection: some View {
        Section {
            Picker(t("settings.audio.source"), selection: $model.sourceBundleID) {
                if !sources.contains(where: { $0.bundleID == model.sourceBundleID }) {
                    Text(model.sourceBundleID).tag(model.sourceBundleID)
                    Divider()
                }
                ForEach(sources) { source in
                    Text(source.isProducingAudio
                         ? "\(source.name)  ·  \(t("settings.audio.source.active"))"
                         : source.name)
                        .tag(source.bundleID)
                }
            }
            .disabled(model.isRunning)
        } header: {
            Text(t("settings.audio.source.section"))
        } footer: {
            Text(t("settings.audio.source.footer"))
                .font(.App.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var inputSection: some View {
        Section {
            Picker(t("settings.voice.input"), selection: $model.inputDeviceUID) {
                Text(t("settings.voice.input.default")).tag("")
                Divider()
                if !model.inputDeviceUID.isEmpty,
                   !inputs.contains(where: { $0.uid == model.inputDeviceUID }) {
                    Text(t("ux.device.unavailable")).tag(model.inputDeviceUID)
                }
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
                    .font(.App.caption)
                    .foregroundStyle(Theme.pending)
            }
        } header: {
            Text(t("settings.audio.input.section"))
        } footer: {
            Text(t("settings.audio.input.footer"))
                .font(.App.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var incomingSection: some View {
        Section {
            Picker(t("settings.audio.output"),
                   selection: $model.remoteOutputDeviceUID) {
                Text(t("settings.audio.output.default",
                       defaultOutputName ?? t("settings.voice.currentInput.unknown")))
                    .tag("")
                Divider()
                missingOutput(model.remoteOutputDeviceUID)
                outputChoices
            }
            .disabled(model.isRunning)

            AudioVolumeRow(title: t("settings.audio.originalVolume"),
                           value: $model.remoteOriginalVolume)
            AudioVolumeRow(title: t("settings.audio.translationVolume"),
                           value: $model.remoteTranslationVolume,
                           disabled: model.mode == .transcribe)
        } header: {
            Text(t("settings.audio.remote.section"))
        } footer: {
            Text(t("settings.audio.remote.footer"))
                .font(.App.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var outgoingSection: some View {
        Section {
            if model.mode == .transcribe {
                Label(t("settings.voice.transcribe"), systemImage: "info.circle")
                    .font(.App.caption)
                    .foregroundStyle(.secondary)
            } else if model.scope == .remoteOnly {
                Label(t("settings.voice.remoteOnly"), systemImage: "info.circle")
                    .font(.App.caption)
                    .foregroundStyle(.secondary)
            }

            Picker(t("settings.audio.output"), selection: $model.outputDeviceUID) {
                Text(t("settings.voice.device.off")).tag("")
                Divider()
                missingOutput(model.outputDeviceUID)
                outputChoices
            }
            .disabled(model.isRunning)

            AudioVolumeRow(title: t("settings.audio.originalVolume"),
                           value: $model.localOriginalVolume,
                           disabled: model.outputDeviceUID.isEmpty)
            AudioVolumeRow(title: t("settings.audio.translationVolume"),
                           value: $model.localTranslationVolume,
                           disabled: model.outputDeviceUID.isEmpty
                             || model.mode == .transcribe)

        } header: {
            Text(t("settings.audio.local.section"))
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(t("settings.audio.local.footer"))
                Link(t("settings.voice.blackhole"),
                     destination: URL(string: "https://existential.audio/blackhole/")!)
            }
            .font(.App.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var voiceCloneSection: some View {
        Section {
            Toggle(t("settings.voice.clone"), isOn: $model.clonesVoice)
                .disabled(model.isRunning || model.mode == .transcribe
                    || !(model.speaksRemoteTranslation || model.speaksTranslation))
        } footer: {
            Text(t("settings.voice.clone.footer"))
                .font(.App.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var outputChoices: some View {
        ForEach(outputs) { device in
            Text(device.hasInputStreams
                 ? "\(device.name)  ·  \(t("settings.voice.device.loopback"))"
                 : device.name)
                .tag(device.uid ?? "")
        }
    }

    @ViewBuilder
    private func missingOutput(_ uid: String) -> some View {
        if !uid.isEmpty, !outputs.contains(where: { $0.uid == uid }) {
            Text(t("ux.device.unavailable")).tag(uid)
        }
    }

    private func reload() {
        guard !isReloading else { return }
        isReloading = true
        Task {
            defer { isReloading = false }
            let snapshot = await Task.detached(priority: .userInitiated) {
                (
                    AudioOutputDevice.outputs(),
                    AudioInputDevice.inputs(),
                    AudioOutputDevice.systemDefault?.name,
                    AudioSourceApplication.available()
                )
            }.value
            outputs = snapshot.0
            inputs = snapshot.1
            defaultOutputName = snapshot.2
            sources = snapshot.3
        }
    }
}

private struct AudioVolumeRow: View {
    let title: String
    @Binding var value: Double
    var disabled = false
    @State private var previousVolume = 1.0

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 120, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    if value > 0 {
                        previousVolume = value
                        value = 0
                    } else {
                        value = previousVolume
                    }
                } label: {
                    Image(systemName: value == 0 ? "speaker.slash.fill" : "speaker.wave.2")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help(t(value == 0 ? "ux.unmute" : "ux.mute"))
                .accessibilityLabel(title + " · " + t(value == 0 ? "ux.unmute" : "ux.mute"))
                AlignedSlider(value: $value, range: 0...2, step: 0.05, label: title)
                    .accessibilityLabel(title)
                    .accessibilityValue(value.formatted(.percent.precision(.fractionLength(0))))
                    .frame(minWidth: 130, maxWidth: .infinity)
                Text(value, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 32)
        .disabled(disabled)
        .accessibilityElement(children: .contain)
    }
}
