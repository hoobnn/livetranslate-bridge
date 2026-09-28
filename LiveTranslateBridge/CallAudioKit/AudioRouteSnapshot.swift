import CoreAudio
import Foundation

/// Only selected endpoints participate, so creating our private process-tap
/// aggregate does not trigger a recovery loop. Read on a utility worker.
///
/// IO buffer size is deliberately not part of it: other apps (a DAW, a
/// conferencing client) resize a shared device's buffer routinely, the
/// engines absorb that on their own, and treating it as a route change tore
/// down the whole session — translation sockets included.
nonisolated struct AudioRouteSnapshot: Equatable, Sendable {
    struct Endpoint: Equatable, Sendable {
        let id: AudioDeviceID
        let sampleRate: Double
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
        // Every stream, not the first: a member joining or leaving an
        // aggregate changes the stream list and leaves stream one as it was.
        return Endpoint(id: id,
            sampleRate: AudioObject.value(id, kAudioDevicePropertyNominalSampleRate, default: 0.0),
            alive: AudioObject.value(id, kAudioDevicePropertyDeviceIsAlive, default: UInt32(0)),
            channels: UInt32(AudioObject.channelCount(id, scope: scope)))
    }
}

/// Watches the selected endpoints through Core Audio property listeners and
/// reports a changed snapshot once, after a short debounce: unplugging a
/// headset fires several notifications (device list, default device, alive)
/// that describe one event. A slow poll backstops listeners that never fire,
/// for example on a device that was absent when they were attached.
nonisolated final class AudioRouteWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.livetranslate.route-watch", qos: .utility)
    private let read: @Sendable () -> AudioRouteSnapshot
    private let onChange: @Sendable () -> Void
    private var previous: AudioRouteSnapshot?
    private var block: AudioObjectPropertyListenerBlock?
    private var watchedDevices: [AudioDeviceID] = []
    private var pending: DispatchWorkItem?
    private var backstop: DispatchSourceTimer?
    private var running = false

    private static let systemSelectors = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDefaultOutputDevice,
    ]
    private static let deviceSelectors = [
        kAudioDevicePropertyDeviceIsAlive,
        kAudioDevicePropertyNominalSampleRate,
        kAudioDevicePropertyStreamConfiguration,
    ]

    init(read: @escaping @Sendable () -> AudioRouteSnapshot,
         onChange: @escaping @Sendable () -> Void) {
        self.read = read
        self.onChange = onChange
    }

    deinit { detach() }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.schedule() }
            self.block = block
            for selector in Self.systemSelectors {
                var address = AudioObject.address(selector)
                AudioObjectAddPropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
            }
            let snapshot = read()
            previous = snapshot
            watch(snapshot)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in self?.evaluate() }
            timer.resume()
            backstop = timer
        }
    }

    func stop() { queue.sync { detach() } }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluate() }
        pending = work
        queue.asyncAfter(deadline: .now() + .milliseconds(300), execute: work)
    }

    private func evaluate() {
        guard running else { return }
        let snapshot = read()
        watch(snapshot)
        guard snapshot != previous else { return }
        previous = snapshot
        onChange()
    }

    private func watch(_ snapshot: AudioRouteSnapshot) {
        let devices = Array(Set([snapshot.input?.id, snapshot.remote?.id, snapshot.local?.id]
            .compactMap { $0 })).sorted()
        guard devices != watchedDevices, let block else { return }
        unwatchDevices()
        for device in devices {
            for selector in Self.deviceSelectors {
                var address = AudioObject.address(selector, scope: kAudioObjectPropertyScopeWildcard)
                AudioObjectAddPropertyListenerBlock(device, &address, queue, block)
            }
        }
        watchedDevices = devices
    }

    private func unwatchDevices() {
        guard let block else { return }
        for device in watchedDevices {
            for selector in Self.deviceSelectors {
                var address = AudioObject.address(selector, scope: kAudioObjectPropertyScopeWildcard)
                AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)
            }
        }
        watchedDevices = []
    }

    private func detach() {
        guard running else { return }
        running = false
        pending?.cancel()
        pending = nil
        backstop?.cancel()
        backstop = nil
        unwatchDevices()
        if let block {
            for selector in Self.systemSelectors {
                var address = AudioObject.address(selector)
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
            }
        }
        block = nil
        previous = nil
    }
}

nonisolated enum AudioRoutePolicy {
    static func missingExplicitInput(uid: String, resolved: AudioInputDevice?) -> Bool {
        !uid.isEmpty && resolved == nil
    }
    /// Whether the input would read back what the app plays: a loopback
    /// (itself, or a member of an aggregate) that is also one of the outputs
    /// (itself, or a member of a multi-output device).
    static func feedsOwnOutput(input: AudioInputDevice?, outputs: [AudioOutputDevice?]) -> Bool {
        guard let input else { return false }
        let played = outputs.compactMap { $0 }.reduce(into: Set<String>()) { $0.formUnion($1.routeUIDs) }
        return !input.loopbackUIDs.isDisjoint(with: played)
    }
}
