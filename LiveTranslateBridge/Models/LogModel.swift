import Foundation
import Observation

/// Backs the live log pane: subscribes to `LogStore` and keeps the lines the
/// current filter admits.
///
/// The store is the source of truth and is never drained; this holds a
/// filtered view of it, rebuilt when the filter changes and appended to as
/// batches arrive.
@MainActor
@Observable
final class LogModel {
    private(set) var lines: [LogStore.Line] = []

    /// Categories the pane shows. Empty is not reachable from the UI — the
    /// last enabled chip cannot be turned off — but is handled as "show all"
    /// rather than an empty pane.
    var categories: Set<LogCategory> = Set(LogCategory.allCases) {
        didSet { if categories != oldValue { rebuild() } }
    }

    var minimumLevel: LogLevel = .info {
        didSet { if minimumLevel != oldValue { rebuild() } }
    }

    var isPaused = false {
        didSet {
            // Resuming shows what was missed rather than leaving a gap.
            if !isPaused && isPaused != oldValue { rebuild() }
        }
    }

    /// Kept small enough that the list stays responsive while a call floods
    /// the audio category; the store holds the rest.
    private static let displayLimit = 1000

    init() {
        lines = Self.filtered(LogStore.shared.snapshot(),
                              categories: categories,
                              minimumLevel: minimumLevel)
        LogStore.shared.onAppend = { [weak self] batch in
            self?.append(batch)
        }
    }

    private func append(_ batch: [LogStore.Line]) {
        guard !isPaused else { return }
        let admitted = Self.filtered(batch, categories: categories,
                                     minimumLevel: minimumLevel)
        guard !admitted.isEmpty else { return }
        lines.append(contentsOf: admitted)
        if lines.count > Self.displayLimit {
            lines.removeFirst(lines.count - Self.displayLimit)
        }
    }

    private func rebuild() {
        lines = Self.filtered(LogStore.shared.snapshot(),
                              categories: categories,
                              minimumLevel: minimumLevel)
        if lines.count > Self.displayLimit {
            lines.removeFirst(lines.count - Self.displayLimit)
        }
    }

    func clear() {
        LogStore.shared.clear()
        lines = []
    }

    func toggle(_ category: LogCategory) {
        var next = categories
        if next.contains(category) {
            // Never leave the pane with no category selected: an empty filter
            // reads as a broken log rather than as a choice.
            guard next.count > 1 else { return }
            next.remove(category)
        } else {
            next.insert(category)
        }
        categories = next
    }

    /// The visible lines as text, for the copy button.
    var text: String {
        lines.map { line in
            "\(Self.timestamp.string(from: line.date))  [\(line.category.rawValue)]  \(line.message)"
        }
        .joined(separator: "\n")
    }

    static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func filtered(
        _ lines: [LogStore.Line],
        categories: Set<LogCategory>,
        minimumLevel: LogLevel
    ) -> [LogStore.Line] {
        lines.filter {
            (categories.isEmpty || categories.contains($0.category))
                && $0.level >= minimumLevel
        }
    }
}
