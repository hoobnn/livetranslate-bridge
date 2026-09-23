import os
import AVFoundation
import CoreAudio
import Foundation

/// Captures the far end of a call by tapping the selected app's output.
///
/// The tap follows bundle IDs rather than process objects (macOS 26+): it is
/// created once per session, covers every helper process that renders for
/// the app, and keeps capturing when those processes exit and relaunch. So
/// the first syllable after the app resumes playing is not lost to a
/// tap/aggregate rebuild, and a muted source stays muted throughout.
///
/// A tap is not readable on its own; it has to be wrapped in an aggregate
/// device. Both objects are process-global in the Core Audio server, so they
/// outlive a crash of this process and show up in Audio MIDI Setup as debris.
/// Everything here is built around making that impossible: the ids are torn
/// down in `deinit`, on explicit `stop()`, and any stale aggregates left by a
/// previous run are swept on the next `start()`.
nonisolated public final class DownlinkTap: @unchecked Sendable {
    private static let aggregatePrefix = "call-audio-bridge-agg"
    private static let tapNamePrefix = "call-audio-bridge-tap"

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private let lock = NSLock()

    public private(set) var format: AVAudioFormat?
    public private(set) var bundleIDs: [String] = []
    /// Read once at `start()`; the IO block captures the handler directly so the
    /// realtime thread never touches this object.
    public var onBuffer: (@Sendable (CapturedAudio) -> Void)?

    public init() {}
    deinit { teardown() }

    public func start(bundleIDs: [String], muteSource: Bool = false) throws {
        lock.lock()
        defer { lock.unlock() }
        guard tapID == 0, !bundleIDs.isEmpty else { return }

        Self.sweepStaleAggregates()

        let description = CATapDescription(stereoMixdownOfProcesses: [])
        description.bundleIDs = bundleIDs
        description.isProcessRestoreEnabled = true
        description.name = "\(Self.tapNamePrefix)-\(getpid())"
        description.isPrivate = true
        // When the original is routed through our mixer, suppress the app's
        // direct hardware path so it is heard once and the configured gain
        // applies. Diagnostics leave this at `.unmuted`.
        description.muteBehavior = muteSource ? .mutedWhenTapped : .unmuted

        var newTap: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTap)
        guard tapStatus == noErr, newTap != 0 else {
            throw CallAudioError.status("AudioHardwareCreateProcessTap", tapStatus)
        }
        tapID = newTap

        guard let tapUID = AudioObject.string(newTap, kAudioTapPropertyUID) else {
            teardownLocked()
            throw CallAudioError("tap has no UID")
        }

        // The tap's own format is authoritative; the aggregate's stream format
        // is derived from it and can lag behind during device changes.
        var asbd = AudioStreamBasicDescription()
        var formatAddr = AudioObject.address(kAudioTapPropertyFormat)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let fmtStatus = AudioObjectGetPropertyData(newTap, &formatAddr, 0, nil, &size, &asbd)
        guard fmtStatus == noErr else {
            teardownLocked()
            throw CallAudioError.status("read tap format", fmtStatus)
        }
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32, asbd.mChannelsPerFrame > 0 else {
            teardownLocked()
            throw CallAudioError("unsupported tap format: \(asbd)")
        }

        let aggregateUID = "\(Self.aggregatePrefix)-\(getpid())"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "CallAudioBridge",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceIsStackedKey as String: 0,
            kAudioAggregateDeviceTapAutoStartKey as String: 1,
            kAudioAggregateDeviceSubDeviceListKey as String: [],
            kAudioAggregateDeviceTapListKey as String: [[
                kAudioSubTapUIDKey as String: tapUID,
                kAudioSubTapDriftCompensationKey as String: 1,
            ]],
        ]

        var newAggregate: AudioObjectID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &newAggregate
        )
        guard aggStatus == noErr, newAggregate != 0 else {
            teardownLocked()
            throw CallAudioError.status("AudioHardwareCreateAggregateDevice", aggStatus)
        }
        aggregateID = newAggregate

        let channels = Int(asbd.mChannelsPerFrame)
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let sampleRate = asbd.mSampleRate
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: interleaved
        )

        let handler = onBuffer
        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID, newAggregate, nil
        ) { _, inputData, _, _, _ in
            guard let handler, let buffer = CapturedAudio(
                buffers: inputData, channelCount: channels,
                sampleRate: sampleRate, interleaved: interleaved
            ) else { return }
            handler(buffer)
        }
        guard procStatus == noErr, let procID else {
            teardownLocked()
            throw CallAudioError.status("AudioDeviceCreateIOProcID", procStatus)
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(newAggregate, procID)
        guard startStatus == noErr else {
            teardownLocked()
            throw CallAudioError.status("AudioDeviceStart", startStatus)
        }
        self.bundleIDs = bundleIDs
        BridgeLog.tap.notice(
            "tap running for \(bundleIDs.joined(separator: ","), privacy: .public): \(sampleRate, privacy: .public) Hz \(channels, privacy: .public) ch"
        )
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        teardownLocked()
    }

    private func teardown() {
        lock.lock()
        defer { lock.unlock() }
        teardownLocked()
    }

    private func teardownLocked() {
        if aggregateID != 0, let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
        format = nil
        bundleIDs = []
    }

    /// Removes aggregates this tool created in a previous run that died before
    /// it could clean up. Only our own prefix is touched.
    public static func sweepStaleAggregates() {
        let devices = AudioObject.objectList(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDevices
        )
        let selfUID = "\(aggregatePrefix)-\(getpid())"
        for device in devices {
            guard let uid = AudioObject.string(device, kAudioDevicePropertyDeviceUID),
                  uid.hasPrefix(aggregatePrefix),
                  uid != selfUID else { continue }
            // A live owner keeps its aggregate; only sweep dead ones.
            if let pidPart = uid.split(separator: "-").last,
               let pid = pid_t(pidPart),
               kill(pid, 0) == 0 { continue }
            AudioHardwareDestroyAggregateDevice(device)
        }
    }
}
