import Foundation

/// Decides which 16 kHz mono Int16 chunks are worth uploading.
///
/// The service bills input audio by duration, and a session left running
/// between calls — or through the long silences of one — streamed digital
/// zeros the whole time. The gate stops the upload once a side has been quiet
/// for `hangover` and resumes it on the first loud chunk, prefixed with the
/// `preroll` it held back so the onset of the next word is not clipped.
///
/// The hangover has to outlast the service's own end-of-turn silence
/// (`session.created` reports 2500 ms): stopping sooner would leave the last
/// utterance of a turn without the silence that closes it.
nonisolated struct SilenceGate {
    /// Peak magnitude a chunk must exceed to count as sound.
    let threshold: Int16
    let hangoverBytes: Int
    let prerollBytes: Int

    /// Open at the start, so a fresh session behaves exactly as an ungated
    /// one until the side has actually been quiet.
    private(set) var isOpen = true
    private var quietBytes = 0
    private var preroll: [Data] = []
    private var prerollCount = 0

    /// Exact digital silence, allowing for rounding in the resampler. Safe for
    /// any source: a tap on an app that is not playing reads zeros.
    static func digitalSilence() -> SilenceGate {
        SilenceGate(threshold: 8, hangoverSeconds: 3, prerollSeconds: 0.5)
    }

    /// A microphone never reads zeros, so it is gated on level instead:
    /// −50 dBFS sits above a quiet room and well below speech.
    static func microphone() -> SilenceGate {
        SilenceGate(threshold: 104, hangoverSeconds: 3, prerollSeconds: 0.5)
    }

    init(threshold: Int16, hangoverSeconds: Double, prerollSeconds: Double) {
        let bytesPerSecond = Resampler.targetSampleRate * Double(MemoryLayout<Int16>.size)
        self.threshold = threshold
        hangoverBytes = Int(hangoverSeconds * bytesPerSecond)
        prerollBytes = Int(prerollSeconds * bytesPerSecond)
    }

    /// The chunks to upload now, oldest first; empty while the gate is shut.
    mutating func admit(_ chunk: Data) -> [Data] {
        if Self.peak(of: chunk) > Int(threshold) {
            quietBytes = 0
            guard !isOpen else { return [chunk] }
            isOpen = true
            let released = preroll + [chunk]
            preroll.removeAll(keepingCapacity: true)
            prerollCount = 0
            return released
        }
        if isOpen {
            quietBytes += chunk.count
            if quietBytes >= hangoverBytes { isOpen = false }
            return [chunk]
        }
        preroll.append(chunk)
        prerollCount += chunk.count
        while prerollCount > prerollBytes, !preroll.isEmpty {
            prerollCount -= preroll.removeFirst().count
        }
        return []
    }

    static func peak(of pcm: Data) -> Int {
        pcm.withUnsafeBytes { raw -> Int in
            var loudest: Int32 = 0
            // `Int32` because `abs(Int16.min)` overflows Int16.
            for sample in raw.bindMemory(to: Int16.self) {
                let magnitude = abs(Int32(sample))
                if magnitude > loudest { loudest = magnitude }
            }
            return Int(loudest)
        }
    }
}
