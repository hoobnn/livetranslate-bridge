import Foundation
import os

/// Streams the first response immediately. Interleaved later responses wait
/// until its audio is complete and actually drained, so PCM never interleaves.
nonisolated final class ResponseAudioRouter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.livetranslate.response-audio")
    private weak var player: TranslationPlayer?
    private var active: String?
    private var order: [String] = []
    private var pending: [String: [Data]] = [:]
    private var ended = Set<String>()
    private var retired = Set<String>()
    private var retiredOrder: [String] = []
    private var sourceStops: [String: ContinuousClock.Instant] = [:]
    private var outputSources: [String: String] = [:]
    private var reported = Set<String>()
    private var pendingBytes = 0
    private static let budget = 15 * 24_000 * 2

    init(player: TranslationPlayer) {
        self.player = player
        let upstream = player.onPlaybackChange
        player.onPlaybackChange = { [weak self] playing in
            upstream?(playing)
            if !playing { self?.queue.async { [weak self] in self?.advanceIfDrained() } }
        }
    }

    func accept(_ identity: TranslationClient.EventIdentity, event: TranslationClient.Event) {
        queue.sync {
            if case .itemLinked(let output, let source) = event {
                if outputSources.count >= 2048 { outputSources.removeAll() }
                outputSources[identity.streamID + "/" + output] = identity.streamID + "/" + source
                return
            }
            if case .speechStopped = event, let source = identity.itemID {
                if sourceStops.count >= 2048 { sourceStops.removeAll() }
                sourceStops[identity.streamID + "/" + source] = .now
                return
            }
            guard let id = identity.responseID ?? identity.itemID else { return }
            let key = identity.streamID + "/" + id
            guard !retired.contains(key) else { return }
            switch event {
            case .responseOpened:
                if active != key, pending[key] == nil {
                    order.append(key)
                    pending[key] = []
                }
                advanceIfDrained()
            case .audio(let data):
                guard !ended.contains(key) else { return }
                if reported.insert(key).inserted, let output = identity.itemID,
                   let source = outputSources[identity.streamID + "/" + output],
                   let stopped = sourceStops[source] {
                    BridgeLog.audio.notice("segment timing response=\(key, privacy: .public) source=\(source, privacy: .public) stop-event to first audio receipt=\(String(describing: stopped.duration(to: .now)), privacy: .public) (not hardware latency)")
                }
                let playingBytes = Int((player?.queuedTranslationSeconds ?? 0) * 48_000)
                guard pendingBytes + playingBytes + data.count <= Self.budget else {
                    if active == key {
                        ended.insert(key)
                        if retired.insert(key).inserted { retiredOrder.append(key) }
                    } else { discard(key) }
                    player?.onWarning?("audio.backlog")
                    advanceIfDrained()
                    return
                }
                if active == nil { active = key; player?.responseEnded() }
                if active == key { player?.enqueue(data) }
                else {
                    if pending[key] == nil { order.append(key) }
                    pending[key, default: []].append(data)
                    pendingBytes += data.count
                }
            case .audioComplete:
                guard active == key || pending[key] != nil else { discard(key); return }
                ended.insert(key)
                advanceIfDrained()
            case .responseFinished(let status):
                if status != "completed" {
                    if active == key {
                        player?.flush()
                        player?.responseEnded()
                        active = nil
                    }
                    discard(key)
                } else if active == key || pending[key] != nil { ended.insert(key) }
                else { discard(key) }
                advanceIfDrained()
            default: break
            }
        }
    }

    func interrupt() {
        queue.sync {
            if let active { discard(active) }
            for key in order { discard(key) }
            active = nil
            player?.flush()
            player?.responseEnded()
        }
    }

    private func advanceIfDrained() {
        if let active {
            guard ended.contains(active), player?.isPlaying != true else { return }
            discard(active)
            self.active = nil
        }
        while active == nil, !order.isEmpty {
            let key = order.removeFirst()
            let chunks = pending.removeValue(forKey: key) ?? []
            pendingBytes -= chunks.reduce(0) { $0 + $1.count }
            guard !retired.contains(key) else { continue }
            active = key
            player?.responseEnded()
            for chunk in chunks { player?.enqueue(chunk) }
            if ended.contains(key), player?.isPlaying != true {
                discard(key)
                active = nil
            }
        }
    }

    private func discard(_ key: String) {
        pendingBytes -= (pending.removeValue(forKey: key) ?? []).reduce(0) { $0 + $1.count }
        order.removeAll { $0 == key }
        ended.remove(key)
        reported.remove(key)
        if retired.insert(key).inserted { retiredOrder.append(key) }
        while retiredOrder.count > 4096 { retired.remove(retiredOrder.removeFirst()) }
    }

    var activeResponseForTesting: String? { queue.sync { active } }
    var pendingBytesForTesting: Int { queue.sync { pendingBytes } }
}
