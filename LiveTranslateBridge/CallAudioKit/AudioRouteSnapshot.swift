import CoreAudio
import Foundation

/// Only selected endpoints participate, so creating our private process-tap
/// aggregate does not trigger a recovery loop. Read on a utility worker.
nonisolated struct AudioRouteSnapshot: Equatable, Sendable {
    struct Endpoint: Equatable, Sendable {
        let id: AudioDeviceID
        let sampleRate: Double
        let bufferFrames: UInt32
        let alive: UInt32
        let channels: UInt32
    }
    let input: Endpoint?
    let remote: Endpoint?
    let local: Endpoint?

    static func read(inputUID: String?, remoteUID: String?, localUID: String?) -> Self {
        let input = inputUID.flatMap { uid in
            uid.isEmpty ? AudioInputDevice.systemDefault : AudioInputDevice.named(uid: uid)
        }
        let remote = remoteUID.flatMap { uid in
            uid.isEmpty ? AudioOutputDevice.systemDefault : AudioOutputDevice.named(uid: uid)
        }
        let local = localUID.flatMap { AudioOutputDevice.named(uid: $0) }
        return Self(input: endpoint(input?.id, input: true),
                    remote: endpoint(remote?.id, input: false),
                    local: endpoint(local?.id, input: false))
    }

    private static func endpoint(_ id: AudioDeviceID?, input: Bool) -> Endpoint? {
        guard let id else { return nil }
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        var format = AudioStreamBasicDescription()
        var address = AudioObject.address(kAudioDevicePropertyStreamFormat, scope: scope)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &format)
        return Endpoint(id: id,
            sampleRate: AudioObject.value(id, kAudioDevicePropertyNominalSampleRate, default: 0.0),
            bufferFrames: AudioObject.value(id, kAudioDevicePropertyBufferFrameSize, default: UInt32(0)),
            alive: AudioObject.value(id, kAudioDevicePropertyDeviceIsAlive, default: UInt32(0)),
            channels: format.mChannelsPerFrame)
    }
}

nonisolated enum AudioRoutePolicy {
    static func missingExplicitInput(uid: String, resolved: AudioInputDevice?) -> Bool {
        !uid.isEmpty && resolved == nil
    }
    static func feedsOwnOutput(inputUID: String?, inputIsLoopback: Bool, localUID: String, remoteUID: String?) -> Bool {
        guard inputIsLoopback, let inputUID, !inputUID.isEmpty else { return false }
        return (!localUID.isEmpty && inputUID == localUID) || inputUID == remoteUID
    }
}
