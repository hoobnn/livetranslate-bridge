import AVFoundation
import Foundation

/// Coalesces socket text deltas into one main-actor delivery per display
/// frame. Audio bypasses the batch entirely and goes straight to playback.
nonisolated final class TranslationEventBatcher: @unchecked Sendable {
    private let queue: DispatchQueue
    private let deliver: @Sendable ([TranslationClient.Event]) -> Void
    private let deliverAudio: @Sendable (Data) -> Void
    private var pending: [TranslationClient.Event] = []
    private var scheduled = false

    init(
        label: String,
        deliver: @escaping @Sendable ([TranslationClient.Event]) -> Void,
        deliverAudio: @escaping @Sendable (Data) -> Void
    ) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        self.deliver = deliver
        self.deliverAudio = deliverAudio
    }

    func submit(_ event: TranslationClient.Event) {
        if case .audio(let data) = event {
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
        switch event {
        case .transcriptComplete, .translationComplete, .failed,
             .finished, .sessionReady:
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

    func install(_ player: TranslationPlayer?) {
        lock.lock()
        let previous = self.player
        self.player = player
        lock.unlock()
        if previous !== player { previous?.stop() }
    }

    func enqueue(_ data: Data) {
        lock.lock()
        let player = self.player
        lock.unlock()
        player?.enqueue(data)
    }

    @available(macOS 14.2, *)
    func enqueueOriginal(_ buffer: DownlinkTap.Buffer) {
        lock.lock()
        let player = self.player
        lock.unlock()
        player?.enqueueOriginal(buffer)
    }

    func enqueueOriginal(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let player = self.player
        lock.unlock()
        player?.enqueueOriginal(buffer)
    }

    func stop() { install(nil) }
}
