import SwiftUI
import UniformTypeIdentifiers

/// Debug panel: the old CLI's `status`, `levels`, `clean` and `translate-file`
/// as a view, so the capture chain can be checked without a real call.
struct DiagnosticsView: View {
    @Bindable var model: SubtitleModel
    @State private var diagnostics = DiagnosticsModel()
    @State private var isPickingFile = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                Text(t("diagnostics.subtitle"))
                    .font(.App.body)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.spacing4)

                processSection
                levelSection
                fileSection
                maintenanceSection
            }
            .padding(Theme.pageInset)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            diagnostics.refreshProcessReport(sourceBundleID: model.sourceBundleID)
        }
        .onDisappear { diagnostics.stopMetering() }
        // A session started or stopped while the panel is open: hand the
        // microphone over, or take it back.
        .onChange(of: model.isRunning && model.runningScope.captures(.local)) { _, owns in
            diagnostics.setSessionOwnsInput(owns)
        }
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: [.wav, .audio]
        ) { result in
            guard case .success(let url) = result else { return }
            // A file chosen through the panel comes with a scoped grant that
            // has to be opened explicitly, even with the sandbox off.
            let scoped = url.startAccessingSecurityScopedResource()
            diagnostics.streamFile(at: url, using: model)
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
    }

    // MARK: - process

    private var processSection: some View {
        Card(t("diagnostics.process.title")) {
            ProcessReport(report: diagnostics.processReport)

            Button {
                withAnimation(Theme.settle) {
                    diagnostics.refreshProcessReport(
                        sourceBundleID: model.sourceBundleID
                    )
                }
            } label: {
                Label(t("diagnostics.process.recheck"), systemImage: "arrow.clockwise")
            }
        }
    }

    // MARK: - levels

    private var levelSection: some View {
        Card(t("diagnostics.levels.title"),
             subtitle: t("diagnostics.levels.note")) {
            VStack(spacing: 8) {
                LevelBar(label: "DL", peak: diagnostics.downlinkPeak)
                LevelBar(label: "UL", peak: diagnostics.uplinkPeak)
            }
            .padding(12)
            .well()

            Button(role: diagnostics.isMetering ? .destructive : nil) {
                if diagnostics.isMetering {
                    diagnostics.stopMetering()
                } else {
                    diagnostics.startMetering(
                        sourceBundleID: model.sourceBundleID,
                        inputDevice: AudioInputDevice.named(uid: model.inputDeviceUID),
                        // A running session already holds the microphone; the
                        // meter shows the downlink only until it lets go.
                        sessionOwnsInput: model.isRunning
                            && model.runningScope.captures(.local)
                    )
                }
            } label: {
                Label(
                    diagnostics.isMetering
                        ? t("diagnostics.levels.stop") : t("diagnostics.levels.start"),
                    systemImage: diagnostics.isMetering ? "stop.fill" : "play.fill"
                )
            }
        }
    }

    // MARK: - offline file

    private var fileSection: some View {
        Card(t("diagnostics.file.title"),
             subtitle: t("diagnostics.file.note")) {
            HStack(spacing: 10) {
                Button {
                    isPickingFile = true
                } label: {
                    Label(t("diagnostics.file.choose"), systemImage: "folder")
                }
                .disabled(diagnostics.isStreamingFile)

                if diagnostics.isStreamingFile {
                    ProgressView().controlSize(.small)
                    Button(t("diagnostics.file.cancel"), role: .destructive) {
                        diagnostics.cancelFileStream()
                    }
                }
            }

            if !diagnostics.fileLines.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(diagnostics.fileLines.enumerated()), id: \.offset) {
                        _, line in
                        Text(line.display)
                            .font(.App.body)
                            .foregroundStyle(line.isError ? Color.red : .primary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .well()
            }
        }
    }

    // MARK: - maintenance

    private var maintenanceSection: some View {
        Card(t("diagnostics.maintenance.title"),
             subtitle: t("diagnostics.maintenance.note")) {
            Button {
                withAnimation(Theme.settle) { diagnostics.sweepStaleAggregates() }
            } label: {
                Label(t("diagnostics.maintenance.sweep"), systemImage: "trash")
            }

            if diagnostics.didSweep {
                Label(t("diagnostics.maintenance.swept"), systemImage: "checkmark.circle")
                    .font(.App.body)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - process readout

/// The process report as labelled rows rather than a preformatted block, so
/// the field names localize and the values line up without padding by hand.
private struct ProcessReport: View {
    let report: DiagnosticsModel.ProcessReport

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
            switch report {
            case .notChecked:
                Text(t("diagnostics.process.notChecked"))
                    .font(.App.body)
                    .foregroundStyle(.secondary)

            case .noCall:
                row(t("diagnostics.process.field.process"),
                    t("diagnostics.process.notRegistered"), mono: false)
                row(t("diagnostics.process.field.state"),
                    t("diagnostics.process.noCall"), mono: false)

            case .found(let bundleID, let pid, let input, let output, let active):
                row(t("diagnostics.process.field.process"),
                    "\(bundleID) · \(t("status.pid", pid))")
                row(t("diagnostics.process.field.input"), flag(input), mono: false)
                row(t("diagnostics.process.field.output"), flag(output), mono: false)
                row(t("diagnostics.process.field.state"),
                    active ? t("diagnostics.process.flowing")
                           : t("diagnostics.process.idle"),
                    mono: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .well()
    }

    private func flag(_ value: Bool) -> String {
        value ? t("common.yes") : t("common.no")
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String, mono: Bool = true) -> some View {
        GridRow {
            Text(label)
                .font(.App.body)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .font(mono ? .App.mono : .App.body)
                .textSelection(.enabled)
        }
    }
}

// MARK: - level bar

private struct LevelBar: View {
    let label: String
    let peak: Float

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.App.mono)
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .leading)

            Text(String(format: "%6.1f dB", decibels))
                .font(.App.mono)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            // The track sets the row's height; the reader sizing the fill sits
            // inside it as an overlay rather than being the bar itself. As the
            // bar proper a `GeometryReader` is greedy in both axes, which is
            // what let a meter redrawing many times a second push the rows
            // around it as the level moved.
            Capsule()
                .fill(.quaternary)
                .frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { geometry in
                        Capsule()
                            .fill(fill)
                            .frame(width: geometry.size.width * fraction)
                    }
                }
                .animation(.easeOut(duration: 0.08), value: fraction)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(String(format: "%.0f dB", decibels))
    }

    /// Green through the usable range, amber approaching full scale, red at
    /// clipping — the reading a level meter is for.
    private var fill: LinearGradient {
        let color: Color = peak > 0.99 ? .red : (decibels > -6 ? .orange : .green)
        return LinearGradient(
            colors: [color.opacity(0.75), color],
            startPoint: .leading, endPoint: .trailing
        )
    }

    /// −60 dBFS is the noise floor worth drawing; below that the bar is empty.
    private var decibels: Float { peak > 0 ? 20 * log10(peak) : -120 }
    private var fraction: CGFloat {
        CGFloat(max(0, min(1, (decibels + 60) / 60)))
    }
}

#Preview {
    DiagnosticsView(model: SubtitleModel())
        .background { AppCanvas() }
        .frame(width: 620, height: 560)
}
