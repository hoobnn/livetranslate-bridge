import SwiftUI

/// High-frequency audio choices shown beside the session controls.
struct AudioRoutingSettings: View {
    @Bindable var model: SubtitleModel

    @State private var outputs: [AudioOutputDevice] = []
    @State private var inputs: [AudioInputDevice] = []
    @State private var sources: [AudioSourceApplication] = []
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
                    .font(.headline)
                Spacer()
                Button(t("settings.voice.refresh"), systemImage: "arrow.clockwise") {
                    reload()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()

            Form {
                sourceSection
                inputSection
                incomingSection
                outgoingSection
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
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var inputSection: some View {
        Section {
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
        } header: {
            Text(t("settings.audio.input.section"))
        } footer: {
            Text(t("settings.audio.input.footer"))
                .font(.caption)
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
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var outgoingSection: some View {
        Section {
            if model.mode == .transcribe {
                Label(t("settings.voice.transcribe"), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.scope == .remoteOnly {
                Label(t("settings.voice.remoteOnly"), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker(t("settings.audio.output"), selection: $model.outputDeviceUID) {
                Text(t("settings.voice.device.off")).tag("")
                Divider()
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

            Toggle(t("settings.voice.clone"), isOn: $model.clonesVoice)
                .disabled(model.isRunning || !model.speaksTranslation)
        } header: {
            Text(t("settings.audio.local.section"))
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(t("settings.audio.local.footer"))
                Text(t("settings.voice.clone.footer"))
                Link(t("settings.voice.blackhole"),
                     destination: URL(string: "https://existential.audio/blackhole/")!)
            }
            .font(.caption)
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

    private func reload() {
        Task {
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

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: $value, in: 0...2, step: 0.05)
                    .frame(minWidth: 180)
                Text(value, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
        .disabled(disabled)
    }
}
