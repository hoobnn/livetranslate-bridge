import Foundation
import Observation
import os

/// The sessions kept after the board has moved on, newest first.
///
/// One JSON file per session, named by its id, so saving a session rewrites
/// only that session and deleting one is deleting a file. The list is held
/// in memory in full: it is text, and a history pane that has to fetch each
/// transcript before it can show it is slower to read than one that already
/// has it.
///
/// A `nil` directory keeps everything in memory — the default for a model
/// built by a test or a preview, which must never write into the real app's
/// history.
@MainActor
@Observable
final class SessionHistory {
    private(set) var records: [SessionRecord] = []
    /// False until the first read of the directory has come back, so the
    /// history pane can tell "no history" from "not loaded yet".
    private(set) var isLoaded = false

    @ObservationIgnored let directory: URL?

    init(directory: URL?) {
        self.directory = directory
        guard let directory else {
            isLoaded = true
            return
        }
        // Reading every file can take a moment on a long history; keep it
        // off the main actor so the window opens without waiting for it.
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) {
                Self.readAll(in: directory)
            }.value
            guard let self else { return }
            // A session saved while the load was in flight is newer than
            // anything on disk for the same id.
            let saved = Set(self.records.map(\.id))
            self.records = Self.sorted(self.records + loaded.filter { !saved.contains($0.id) })
            self.isLoaded = true
        }
    }

    /// `~/Library/Application Support/<bundle id>/Sessions`.
    static var defaultDirectory: URL? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let bundleID = Bundle.main.bundleIdentifier ?? "LiveTranslateBridge"
        return support
            .appending(path: bundleID, directoryHint: .isDirectory)
            .appending(path: "Sessions", directoryHint: .isDirectory)
    }

    func record(id: SessionRecord.ID) -> SessionRecord? {
        records.first { $0.id == id }
    }

    /// Inserts or replaces the session with this id. The live session is
    /// saved repeatedly as it grows, always under the same id.
    ///
    /// `synchronously` is for app termination, where a write handed to a
    /// background task would be cut off with the process.
    func save(_ record: SessionRecord, synchronously: Bool = false) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            guard records[index] != record else { return }
            records[index] = record
        } else {
            records = Self.sorted(records + [record])
        }
        guard let directory else { return }
        if synchronously {
            Self.write(record, in: directory)
        } else {
            Task.detached(priority: .utility) { Self.write(record, in: directory) }
        }
    }

    func delete(_ id: SessionRecord.ID) {
        records.removeAll { $0.id == id }
        guard let directory else { return }
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: Self.file(for: id, in: directory))
        }
    }

    func deleteAll(except kept: SessionRecord.ID? = nil) {
        let doomed = records.map(\.id).filter { $0 != kept }
        records.removeAll { $0.id != kept }
        guard let directory else { return }
        Task.detached(priority: .utility) {
            for id in doomed {
                try? FileManager.default.removeItem(at: Self.file(for: id, in: directory))
            }
        }
    }

    // MARK: - disk

    private nonisolated static let log = Logger(
        subsystem: "com.livetranslate.bridge", category: "history"
    )

    private nonisolated static func file(for id: UUID, in directory: URL) -> URL {
        directory.appending(path: id.uuidString + ".json", directoryHint: .notDirectory)
    }

    private nonisolated static func sorted(_ records: [SessionRecord]) -> [SessionRecord] {
        records.sorted { $0.startedAt > $1.startedAt }
    }

    private nonisolated static func write(_ record: SessionRecord, in directory: URL) {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(record)
            try data.write(to: file(for: record.id, in: directory), options: .atomic)
        } catch {
            log.error("session save failed: \("\(error)", privacy: .public)")
        }
    }

    nonisolated static func readAll(in directory: URL) -> [SessionRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        let decoder = JSONDecoder()
        let records = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> SessionRecord? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(SessionRecord.self, from: data)
            }
        return sorted(records)
    }
}
