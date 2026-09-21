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
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                processSection
                levelSection
                fileSection
                maintenanceSection
            }
            .padding(Theme.pageInset)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background { AppCanvas() }
        .onAppear {
            diagnostics.refreshProcessReport(sourceBundleID: model.sourceBundleID)
        }
        .onDisappear { diagnostics.stopMetering() }
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
        Card(t("diagnostics.process.title"), systemImage: "phone.connection") {
            ProcessReport(report: diagnostics.processReport)

            Button {
                withAnimation(.snappy) {
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
             systemImage: "waveform",
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
                        inputDevice: AudioInputDevice.named(uid: model.inputDeviceUID)
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
             systemImage: "waveform.badge.plus",
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
                            .font(.callout)
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
             systemImage: "wrench.and.screwdriver",
             subtitle: t("diagnostics.maintenance.note")) {
            Button {
                withAnimation(.snappy) { diagnostics.sweepStaleAggregates() }
            } label: {
                Label(t("diagnostics.maintenance.sweep"), systemImage: "trash")
            }

            if diagnostics.didSweep {
                Label(t("diagnostics.maintenance.swept"), systemImage: "checkmark.circle")
                    .font(.callout)
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
                    .font(.callout)
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
                .font(.callout)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .font(mono ? .callout.monospaced() : .callout)
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
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .leading)

            Text(String(format: "%6.1f dB", decibels))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .monospacedDigit()

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(fill)
                        .frame(width: geometry.size.width * fraction)
                        .animation(.easeOut(duration: 0.08), value: fraction)
                }
            }
            .frame(height: 6)
        }
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
        .frame(width: 620, height: 560)
}
