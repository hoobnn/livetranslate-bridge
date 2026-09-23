import AVFoundation
import Foundation

/// Coalesces socket text deltas into one main-actor delivery per display
/// frame. Audio bypasses the batch entirely and goes straight to playback.
nonisolated final class TranslationEventBatcher: @unchecked Sendable {
    private let queue: DispatchQueue
    private let deliver: @Sendable ([TranslationClient.Event]) -> Void
    private let deliverAudio: @Sendable (Data) -> Void
    private let audioEvent: @Sendable (TranslationClient.Event) -> Void
    private var pending: [TranslationClient.Event] = []
    private var scheduled = false

    init(
        label: String,
        deliver: @escaping @Sendable ([TranslationClient.Event]) -> Void,
        deliverAudio: @escaping @Sendable (Data) -> Void,
        audioEvent: @escaping @Sendable (TranslationClient.Event) -> Void = { _ in }
    ) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        self.deliver = deliver
        self.deliverAudio = deliverAudio
        self.audioEvent = audioEvent
    }

    func submit(_ event: TranslationClient.Event) {
        audioEvent(event)
        if case .audio(let data) = event.payload {
            if case .identified = event { return }
            deliverAudio(data)
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.pending.append(event)
            if self.isTerminal(event) {
                self.flush()
            } else if !self.scheduled {
                self.scheduled = true
                self.queue.asyncAfter(deadline: .now() + .milliseconds(16)) {
                    [weak self] in self?.flush()
                }
            }
        }
    }

    private func isTerminal(_ event: TranslationClient.Event) -> Bool {
        switch event.payload {
        case .transcriptComplete, .translationComplete, .failed,
             .finished, .sessionReady, .responseFinished, .itemLinked, .streamStarted:
            return true
        default:
            return false
        }
    }

    private func flush() {
        guard !pending.isEmpty else { scheduled = false; return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        scheduled = false
        deliver(batch)
    }
}

/// Thread-safe indirection that keeps decoded speech off the main actor.
nonisolated final class TranslationPlaybackPath: @unchecked Sendable {
    private let lock = NSLock()
    private var player: TranslationPlayer?
    private var responseRouter: ResponseAudioRouter?
    private var generation = 0
    private final class Callback: @unchecked Sendable { weak var owner: TranslationPlaybackPath? }
    private let callback: Callback
    private let originalQueue: RealtimeAudioQueue

    init() {
        let callback = Callback()
        self.callback = callback
        originalQueue = RealtimeAudioQueue(label: "app.livetranslate.playback-handoff", maximumAge: 0.25) {
            [weak callback] buffer in
            callback?.owner?.playOriginal(buffer)
        } onDrop: { count in
            BridgeLog.audio.notice("playback handoff dropped \(count) stale/full buffers")
        }
        callback.owner = self
    }

    var token: Int {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    func install(_ player: TranslationPlayer?) {
        originalQueue.invalidate()
        lock.lock()
        let previous = self.player
        self.player = player
        responseRouter = player.map { ResponseAudioRouter(player: $0) }
        generation &+= 1
        lock.unlock()
        if previous !== player { previous?.stop() }
    }

    func enqueue(_ data: Data, token: Int? = nil) {
        lock.lock()
        guard token == nil || token == generation else { lock.unlock(); return }
        let player = self.player
        lock.unlock()
        player?.enqueue(data)
    }

    func setVolumes(original: Float, translation: Float) {
        lock.lock()
        let player = self.player
        lock.unlock()
        player?.setVolumes(original: original, translation: translation)
    }

    func enqueueOriginal(_ buffer: CapturedAudio) { originalQueue.enqueue(buffer) }

    func enqueueOriginal(_ buffer: AVAudioPCMBuffer) { originalQueue.enqueue(buffer) }

    private func playOriginal(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let player = self.player
        lock.unlock()
        player?.enqueueStagedOriginal(buffer)
    }

    func audioEvent(_ event: TranslationClient.Event, token: Int? = nil) {
        lock.lock()
        guard token == nil || token == generation else { lock.unlock(); return }
        let player = self.player
        let router = responseRouter
        lock.unlock()
        if case .identified(let identity, let payload) = event {
            router?.accept(identity, event: payload)
            return
        }
        switch event {
        case .audioComplete, .sessionReady: player?.responseEnded()
        case .streamStarted: router?.interrupt()
        case .speechStopped: player?.speechStopped()
        default: break
        }
    }

    func interrupt() {
        lock.lock()
        let player = self.player
        let router = responseRouter
        lock.unlock()
        if let router { router.interrupt() } else { player?.flush() }
    }

    func stop() { install(nil) }
}
