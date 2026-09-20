import os
import AVFoundation
import CoreAudio
import Foundation

/// Captures the far end of a call by tapping the audio daemon's output.
///
/// A tap is not readable on its own; it has to be wrapped in an aggregate
/// device. Both objects are process-global in the Core Audio server, so they
/// outlive a crash of this process and show up in Audio MIDI Setup as debris.
/// Everything here is built around making that impossible: the ids are torn
/// down in `deinit`, on explicit `stop()`, and any stale aggregates left by a
/// previous run are swept on the next `start()`.
@available(macOS 14.2, *)
nonisolated public final class DownlinkTap: @unchecked Sendable {
    public struct Buffer: @unchecked Sendable {
        public let samples: UnsafePointer<Float>
        public let frameCount: Int
        public let channelCount: Int
        public let sampleRate: Double
    }

    private static let aggregatePrefix = "call-audio-bridge-agg"
    private static let tapNamePrefix = "call-audio-bridge-tap"

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private let lock = NSLock()

    public private(set) var format: AVAudioFormat?
    public var onBuffer: (@Sendable (Buffer) -> Void)?

    public init() {}
    deinit { teardown() }

    public func start(processObjectID: AudioObjectID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard tapID == 0 else { return }

        Self.sweepStaleAggregates()

        let description = CATapDescription(
            stereoMixdownOfProcesses: [processObjectID]
        )
        description.name = "\(Self.tapNamePrefix)-\(getpid())"
        description.isPrivate = true
        // muteBehavior is left at its default (CATapUnmuted) so the user keeps
        // hearing the call while we capture it.

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

        let aggregateUID = "\(Self.aggregatePrefix)-\(getpid())"
        let description2: [String: Any] = [
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
            description2 as CFDictionary, &newAggregate
        )
        guard aggStatus == noErr, newAggregate != 0 else {
            teardownLocked()
            throw CallAudioError.status("AudioHardwareCreateAggregateDevice", aggStatus)
        }
        aggregateID = newAggregate

        var streamAddr = AudioObject.address(
            kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let fmtStatus = AudioObjectGetPropertyData(
            newAggregate, &streamAddr, 0, nil, &size, &asbd
        )
        guard fmtStatus == noErr else {
            teardownLocked()
            throw CallAudioError.status("read aggregate stream format", fmtStatus)
        }

        let channels = Int(asbd.mChannelsPerFrame)
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.mSampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: true
        )

        let sampleRate = asbd.mSampleRate
        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID, newAggregate, nil
        ) { [weak self] _, inputData, _, _, _ in
            guard let self, let handler = self.onBuffer else { return }
            let list = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inputData)
            )
            guard let first = list.first,
                  first.mDataByteSize > 0,
                  let raw = first.mData else { return }
            let bufferChannels = max(1, Int(first.mNumberChannels))
            let frames = Int(first.mDataByteSize)
                / MemoryLayout<Float>.size / bufferChannels
            guard frames > 0 else { return }
            handler(Buffer(
                samples: raw.assumingMemoryBound(to: Float.self),
                frameCount: frames,
                channelCount: bufferChannels,
                sampleRate: sampleRate
            ))
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
        BridgeLog.tap.notice(
            "tap running: \(asbd.mSampleRate, privacy: .public) Hz \(channels, privacy: .public) ch"
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
