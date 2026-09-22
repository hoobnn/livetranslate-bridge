import AVFoundation
import Accelerate
import Foundation
import Observation
import os
import Synchronization

/// Backs the debug panel, which replaces the old CLI's `status`, `levels`,
/// `clean` and `translate-file` commands.
///
/// These exist so the capture chain can be checked without placing a real call,
/// and so `samples/*.wav` stays usable as a fixed regression input.
@MainActor
@Observable
final class DiagnosticsModel {
    /// What the last process check found. Structured rather than
    /// preformatted, so the view can label the fields in the current
    /// interface language instead of re-rendering the model's text.
    enum ProcessReport: Equatable, Sendable {
        case notChecked
        case noCall
        case found(bundleID: String, pid: Int64, input: Bool, output: Bool, active: Bool)
    }

    /// One line of a `translate-file` run. The source and translation are
    /// service output and stay verbatim; the label in front of them is the
    /// app's, so it carries a key.
    struct FileLine: Identifiable, Equatable, Sendable {
        let id = UUID()
        let kind: Kind
        let text: String

        enum Kind: String, Equatable, Sendable {
            case status
            case source = "diagnostics.file.source"
            case translation = "diagnostics.file.translation"
        }

        @MainActor
        var display: String {
            switch kind {
            case .status: return text
            case .source, .translation:
                return "\(t(kind.rawValue))  \(text)"
            }
        }

        var isError: Bool {
            kind == .status && isErrorStatus
        }

        private let isErrorStatus: Bool

        init(kind: Kind, text: String, isError: Bool = false) {
            self.kind = kind
            self.text = text
            self.isErrorStatus = isError
        }
    }

    private(set) var processReport: ProcessReport = .notChecked
    private(set) var downlinkPeak: Float = 0
    private(set) var uplinkPeak: Float = 0
    private(set) var isMetering = false
    private(set) var didSweep = false

    /// Transcript of a `translate-file` run, newest last.
    private(set) var fileLines: [FileLine] = []
    private(set) var isStreamingFile = false

    private var monitor: CallMonitor?
    private var downlinkTap: DownlinkTap?
    private var uplinkCapture: UplinkCapture?
    /// Whether a running session currently holds the microphone.
    private var sessionOwnsInput = false
    /// Kept so the meter can reopen the same device when the session releases
    /// it, without the view having to hand it over a second time.
    private var meterInputDevice: AudioInputDevice?
    private let meter = Meter()
    private var meterTimer: Timer?
    private var fileTask: Task<Void, Never>?

    /// Peak levels written from the audio threads, drained on a timer.
    private nonisolated final class Meter: @unchecked Sendable {
        private let downlink = Atomic<UInt32>(0)
        private let uplink = Atomic<UInt32>(0)

        func record(downlink value: Float) {
            record(value, into: downlink)
        }
        func record(uplink value: Float) {
            record(value, into: uplink)
        }
        /// Returns the peaks since the last call and resets them.
        func drain() -> (Float, Float) {
            (
                Float(bitPattern: downlink.exchange(
                    0, ordering: .acquiringAndReleasing
                )),
                Float(bitPattern: uplink.exchange(
                    0, ordering: .acquiringAndReleasing
                ))
            )
        }

        private func record(
            _ value: Float,
            into peak: borrowing Atomic<UInt32>
        ) {
            let desired = max(0, value).bitPattern
            var current = peak.load(ordering: .relaxed)
            while desired > current {
                let result = peak.compareExchange(
                    expected: current,
                    desired: desired,
                    ordering: .relaxed
                )
                if result.exchanged { return }
                current = result.original
            }
        }
    }

    // MARK: - status

    func refreshProcessReport(sourceBundleID: String = callAudioBundleID) {
        guard let process = CallMonitor.findAudioProcess(bundleID: sourceBundleID) else {
            processReport = .noCall
            return
        }
        processReport = .found(
            bundleID: sourceBundleID,
            pid: Int64(process.pid),
            input: process.isRunningInput,
            output: process.isRunningOutput,
            active: process.isActive
        )
    }

    // MARK: - levels

    /// Opens the microphone as well, so this is the one panel action that
    /// triggers the microphone permission prompt.
    ///
    /// `sessionOwnsInput` is the running session's claim on the microphone.
    /// The meter opens its own `UplinkCapture` on the same device, and two
    /// `AVAudioEngine`s on one input contend for the AUHAL — the HAL logs
    /// `cannot add handler to N from N - dropping` and one of them gets no
    /// buffers, which reads as a dead meter or a session that hears nothing.
    /// The session wins: it is the feature, the meter is a probe.
    func startMetering(
        sourceBundleID: String = callAudioBundleID,
        inputDevice: AudioInputDevice? = nil,
        sessionOwnsInput: Bool = false
    ) {
        guard !isMetering, #available(macOS 14.2, *) else { return }
        isMetering = true
        self.sessionOwnsInput = sessionOwnsInput

        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.drainMeter() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer

        // The microphone meter is useful without a call, so it must not be
        // coupled to CallMonitor. The downlink tap still follows the call
        // daemon because there is no output process to tap while it is idle.
        meterInputDevice = inputDevice
        if sessionOwnsInput {
            BridgeLog.audio.notice(
                "microphone meter deferred: the running session holds the input device"
            )
        } else {
            startUplinkMeter(device: inputDevice)
        }

        let monitor = CallMonitor(targetBundleID: sourceBundleID)
        monitor.onChange = { [weak self] state in
            Task { @MainActor [weak self] in self?.applyMeteringCallState(state) }
        }
        self.monitor = monitor
        monitor.start()
    }

    func stopMetering() {
        guard isMetering else { return }
        meterTimer?.invalidate()
        meterTimer = nil
        monitor?.stop()
        monitor = nil
        downlinkTap?.stop()
        downlinkTap = nil
        uplinkCapture?.stop()
        uplinkCapture = nil
        isMetering = false
        sessionOwnsInput = false
        meterInputDevice = nil
        downlinkPeak = 0
        uplinkPeak = 0
    }

    /// Follows the session's claim on the microphone while the meter is up.
    ///
    /// Called when a session starts or stops with the panel already open: the
    /// meter yields the input device on the way in and takes it back on the
    /// way out, so the two never hold it at once. The downlink tap is
    /// untouched — a process tap is not exclusive, and the session's own tap
    /// coexists with it.
    func setSessionOwnsInput(_ owns: Bool) {
        guard isMetering, owns != sessionOwnsInput else { return }
        sessionOwnsInput = owns
        if owns {
            uplinkCapture?.stop()
            uplinkCapture = nil
            uplinkPeak = 0
            BridgeLog.audio.notice(
                "microphone meter released the input device to the session"
            )
        } else {
            startUplinkMeter(device: meterInputDevice)
        }
    }

    private func startUplinkMeter(device: AudioInputDevice?) {
        switch AudioCapturePermission.current {
        case .granted:
            openUplinkMeter(device: device)
        case .undetermined:
            AudioCapturePermission.request { [weak self] granted in
                BridgeLog.tap.notice(
                    "microphone requestAccess returned \(granted, privacy: .public); status now \(AudioCapturePermission.rawDescription, privacy: .public)"
                )
                guard granted else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.isMetering else { return }
                    self.openUplinkMeter(device: device)
                }
            }
        case .denied:
            BridgeLog.tap.error(
                "microphone meter unavailable: permission status is \(AudioCapturePermission.rawDescription, privacy: .public)"
            )
        }
    }

    private func openUplinkMeter(device: AudioInputDevice?) {
        guard uplinkCapture == nil, !sessionOwnsInput else { return }
        let capture = UplinkCapture()
        capture.onBuffer = { [meter] buffer in
            guard let data = buffer.floatChannelData?[0] else { return }
            var peak: Float = 0
            vDSP_maxmgv(data, 1, &peak, vDSP_Length(buffer.frameLength))
            meter.record(uplink: peak)
        }
        do {
            try capture.start(device: device)
            uplinkCapture = capture
            BridgeLog.audio.notice("microphone meter running")
        } catch {
            BridgeLog.audio.error("microphone meter did not start: \("\(error)", privacy: .public)")
        }
    }

    private func applyMeteringCallState(_ state: CallState) {
        guard isMetering else { return }
        switch state {
        case .idle:
            downlinkTap?.stop()
            downlinkTap = nil
        case .active(let process):
            guard downlinkTap == nil else { return }
            let tap = DownlinkTap()
            tap.onBuffer = { [meter] buffer in
                var peak: Float = 0
                vDSP_maxmgv(
                    buffer.samples, 1, &peak,
                    vDSP_Length(buffer.frameCount * buffer.channelCount)
                )
                meter.record(downlink: peak)
            }
            do {
                try tap.start(processObjectID: process.objectID)
                downlinkTap = tap
            } catch {
                BridgeLog.tap.error("diagnostic downlink tap did not start: \("\(error)", privacy: .public)")
            }
        }
    }

    private func drainMeter() {
        let (downlink, uplink) = meter.drain()
        // Decay rather than snapping to zero, so a silent frame does not make
        // the meter flicker.
        downlinkPeak = max(downlink, downlinkPeak * 0.6)
        uplinkPeak = max(uplink, uplinkPeak * 0.6)
    }

    // MARK: - clean

    func sweepStaleAggregates() {
        guard #available(macOS 14.2, *) else { return }
        DownlinkTap.sweepStaleAggregates()
        didSweep = true
    }

    // MARK: - translate-file

    /// Streams a WAV through the translation service at wall-clock speed, the
    /// offline path that avoids having to place a call to test a change.
    func streamFile(at url: URL, using model: SubtitleModel) {
        guard !isStreamingFile else { return }
        let credentials = CredentialStore.load()
        guard credentials.isComplete else {
            fileLines = [FileLine(kind: .status,
                                  text: t("diagnostics.file.noCredentials"),
                                  isError: true)]
            return
        }

        let target = Language.named(model.myLanguage)?.endonym
            ?? model.myLanguage
        fileLines = [FileLine(
            kind: .status,
            text: t("diagnostics.file.start", url.lastPathComponent, target)
        )]
        isStreamingFile = true

        let config = TranslationClient.Config(
            apiKey: credentials.apiKey,
            workspaceID: credentials.workspaceID,
            region: model.region,
            targetLanguage: model.myLanguage,
            sourceLanguage: model.theirLanguage,
            wantsAudio: false
        )
        let client = TranslationClient(config: config)
        client.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in self?.appendFileEvent(event) }
        }

        fileTask = Task { [weak self] in
            client.connect()
            // Fail on a bad key here rather than after pacing out the whole
            // file into a socket that was never alive.
            guard await client.waitUntilReady() else {
                await MainActor.run {
                    self?.fileLines.append(FileLine(
                        kind: .status,
                        text: t("diagnostics.file.sessionFailed"),
                        isError: true
                    ))
                    self?.isStreamingFile = false
                }
                client.close()
                return
            }
            do {
                try await Self.stream(url: url, into: client)
            } catch {
                await MainActor.run {
                    self?.fileLines.append(FileLine(
                        kind: .status,
                        text: t("diagnostics.file.readFailed", "\(error)"),
                        isError: true
                    ))
                }
            }
            // The service drops the last utterance unless the session is
            // closed properly.
            await client.finish()
            await MainActor.run { self?.isStreamingFile = false }
        }
    }

    func cancelFileStream() {
        fileTask?.cancel()
        fileTask = nil
        isStreamingFile = false
    }

    private func appendFileEvent(_ event: TranslationClient.Event) {
        switch event.payload {
        case .transcriptComplete(let text):
            if !text.isEmpty { fileLines.append(FileLine(kind: .source, text: text)) }
        case .translationComplete(let text):
            if !text.isEmpty {
                fileLines.append(FileLine(kind: .translation, text: text))
            }
        case .failed(let message):
            fileLines.append(FileLine(kind: .status,
                                      text: t("diagnostics.file.error", message),
                                      isError: true))
        case .finished:
            fileLines.append(FileLine(kind: .status,
                                      text: t("diagnostics.file.finished")))
        default:
            break
        }
    }

    private nonisolated static func stream(
        url: URL, into client: TranslationClient
    ) async throws {
        let file = try AVAudioFile(forReading: url)
        let resampler = try Resampler(sourceFormat: file.processingFormat)

        let framesPerChunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: framesPerChunk
        ) else {
            throw CallAudioError("cannot allocate read buffer")
        }

        // Driven by frame count: reading past the end throws eofErr rather
        // than returning an empty buffer.
        while file.framePosition < file.length {
            if Task.isCancelled || client.isFailed { break }
            let remaining = file.length - file.framePosition
            let toRead = AVAudioFrameCount(min(Int64(framesPerChunk), remaining))
            try file.read(into: buffer, frameCount: toRead)
            guard buffer.frameLength > 0 else { break }
            client.sendAudio(try resampler.convert(buffer))
            // 100 ms per chunk, matching the service's expected input rate.
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
