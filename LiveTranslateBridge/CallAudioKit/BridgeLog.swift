import Foundation
import OSLog

/// Trace points along the capture → resample → socket → subtitle chain.
///
/// The chain crosses a Core Audio IO thread, a URLSession queue and the main
/// actor, and a break anywhere in it looks identical from the UI: the status
/// says subtitling and the board stays empty. These categories exist so the
/// live log says which hop stopped.
///
/// Each line goes to two places: the unified log, readable after the fact with
///     log stream --predicate 'subsystem == "com.livetranslate.bridge"' --level info
/// and `LogStore`, which the app's own log pane reads live. `OSLogStore` could
/// have served the pane too, but it is polled and rate-limited — a ring buffer
/// written at the call site is both cheaper and immediate.
nonisolated public enum BridgeLog {
    private static let subsystem = "com.livetranslate.bridge"

    /// Call detection: whether the audio daemon is seen going active.
    public static let call = BridgeLogger(subsystem: subsystem, category: .call)
    /// Tap creation and the buffers it delivers.
    public static let tap = BridgeLogger(subsystem: subsystem, category: .tap)
    /// Resampling and the bytes handed to the socket.
    public static let audio = BridgeLogger(subsystem: subsystem, category: .audio)
    /// WebSocket lifecycle and the events coming back.
    public static let socket = BridgeLogger(subsystem: subsystem, category: .socket)
}

/// One trace category, and the labels the log pane filters on.
nonisolated public enum LogCategory: String, CaseIterable, Identifiable, Sendable {
    case call
    case tap
    case audio
    case socket

    public var id: String { rawValue }
}

nonisolated public enum LogLevel: String, Comparable, Sendable {
    case info
    case notice
    case error

    private var rank: Int {
        switch self {
        case .info: return 0
        case .notice: return 1
        case .error: return 2
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// A logger that writes each line to the unified log *and* to `LogStore`.
///
/// It takes a `BridgeLogMessage` rather than `OSLogMessage` so the rendered
/// text is available to the app: `OSLogMessage` is opaque by design, and the
/// only way to read a line back would be to query the log store for it. The
/// interpolation accepts the same `privacy:` argument as `Logger` so the
/// existing call sites read unchanged — the marker is honoured on the way to
/// the unified log and ignored on the way to the in-app pane, which never
/// leaves the process.
nonisolated public struct BridgeLogger: Sendable {
    private let logger: Logger
    private let category: LogCategory

    init(subsystem: String, category: LogCategory) {
        self.logger = Logger(subsystem: subsystem, category: category.rawValue)
        self.category = category
    }

    public func info(_ message: BridgeLogMessage) {
        emit(message, level: .info)
    }

    public func notice(_ message: BridgeLogMessage) {
        emit(message, level: .notice)
    }

    public func error(_ message: BridgeLogMessage) {
        emit(message, level: .error)
    }

    private func emit(_ message: BridgeLogMessage, level: LogLevel) {
        let text = message.text
        // `\(text, privacy: .public)` rather than the original literal: the
        // message is already rendered, and its pieces carried their own
        // privacy markers before they got here.
        switch level {
        case .info: logger.info("\(text, privacy: .public)")
        case .notice: logger.notice("\(text, privacy: .public)")
        case .error: logger.error("\(text, privacy: .public)")
        }
        LogStore.shared.append(category: category, level: level, message: text)
    }
}

/// The message a `BridgeLogger` takes, interpolated the way `Logger`'s is.
nonisolated public struct BridgeLogMessage: ExpressibleByStringInterpolation, Sendable {
    let text: String

    public init(stringLiteral value: String) {
        text = value
    }

    public init(stringInterpolation: StringInterpolation) {
        text = stringInterpolation.parts
    }

    /// Mirrors the subset of `OSLogInterpolation` the call sites use. The
    /// `privacy` argument is accepted and discarded: these lines stay inside
    /// the process, and the unified-log copy is emitted as one public string.
    nonisolated public struct StringInterpolation: StringInterpolationProtocol {
        var parts: String = ""

        public init(literalCapacity: Int, interpolationCount: Int) {
            parts.reserveCapacity(literalCapacity + interpolationCount * 8)
        }

        public mutating func appendLiteral(_ literal: String) {
            parts += literal
        }

        public mutating func appendInterpolation(
            _ value: @autoclosure () -> String,
            privacy: OSLogPrivacy = .auto
        ) {
            parts += value()
        }

        public mutating func appendInterpolation<T: CustomStringConvertible>(
            _ value: @autoclosure () -> T,
            privacy: OSLogPrivacy = .auto
        ) {
            parts += String(describing: value())
        }
    }
}

/// The lines behind the app's log pane: a bounded ring the UI observes.
///
/// Writes arrive from the Core Audio IO thread and the URLSession queue, so
/// the buffer is guarded by a lock and the hop to the main actor is batched —
/// a flush every 200 ms rather than a main-actor task per line, which at 48 kHz
/// would be hundreds of hops a second.
nonisolated public final class LogStore: @unchecked Sendable {
    public static let shared = LogStore()

    /// One rendered line.
    public struct Line: Identifiable, Sendable, Equatable {
        public let id: UInt64
        public let date: Date
        public let category: LogCategory
        public let level: LogLevel
        public let message: String
    }

    /// Enough to cover a long call without letting a chatty socket grow the
    /// buffer without bound.
    private static let capacity = 2000

    private let lock = NSLock()
    private var buffer: [Line?] = Array(repeating: nil, count: capacity)
    private var bufferStart = 0
    private var bufferCount = 0
    private var pending: [Line] = []
    private var nextID: UInt64 = 0
    private var isFlushScheduled = false

    /// Called on the main actor whenever new lines have accumulated.
    @MainActor public var onAppend: (([Line]) -> Void)?

    private init() {}

    func append(category: LogCategory, level: LogLevel, message: String) {
        lock.lock()
        let line = Line(id: nextID, date: Date(), category: category,
                        level: level, message: message)
        nextID += 1
        let index = (bufferStart + bufferCount) % Self.capacity
        buffer[index] = line
        if bufferCount < Self.capacity {
            bufferCount += 1
        } else {
            bufferStart = (bufferStart + 1) % Self.capacity
        }
        pending.append(line)
        let shouldSchedule = !isFlushScheduled
        if shouldSchedule { isFlushScheduled = true }
        lock.unlock()

        guard shouldSchedule else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            self.flush()
        }
    }

    @MainActor
    private func flush() {
        lock.lock()
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        isFlushScheduled = false
        lock.unlock()

        guard !batch.isEmpty else { return }
        onAppend?(batch)
    }

    /// Everything still in the ring, for a pane that opens mid-session.
    public func snapshot() -> [Line] {
        lock.lock(); defer { lock.unlock() }
        return (0..<bufferCount).compactMap {
            buffer[(bufferStart + $0) % Self.capacity]
        }
    }

    public func clear() {
        lock.lock()
        buffer = Array(repeating: nil, count: Self.capacity)
        bufferStart = 0
        bufferCount = 0
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
