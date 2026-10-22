import Foundation

/// One session as it is kept after the board has moved on: what was said,
/// and the setup it was said under.
///
/// A plain value, decoupled from the board's observable `Entry` objects, so it
/// can be written to disk off the main actor and read back into the history
/// pane without dragging the utterance state machine along.
///
/// The setup is the one the session *ran* with, not the preference the pickers
/// hold now: by the time anyone rereads a call, the pair may well have been
/// switched for the next one.
nonisolated struct SessionRecord: Codable, Identifiable, Hashable, Sendable {
    /// One utterance, reduced to what a reader needs.
    struct Turn: Codable, Hashable, Sendable {
        var direction: SubtitleModel.Direction
        var startedAt: Date
        var transcript: String
        var translation: String
        /// Spoken by the call agent on our behalf. Absent from sessions
        /// saved before the agent existed, which read back as `false`.
        var isAgent = false
    }

    let id: UUID
    var startedAt: Date
    var endedAt: Date
    var mode: SubtitleModel.SessionMode
    var scope: SubtitleModel.CaptureScope
    var myLanguage: String
    var theirLanguage: String
    var turns: [Turn]

    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
}

nonisolated extension SessionRecord.Turn {
    private enum CodingKeys: String, CodingKey {
        case direction, startedAt, transcript, translation, isAgent
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        direction = try container.decode(SubtitleModel.Direction.self, forKey: .direction)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        transcript = try container.decode(String.self, forKey: .transcript)
        translation = try container.decode(String.self, forKey: .translation)
        isAgent = try container.decodeIfPresent(Bool.self, forKey: .isAgent) ?? false
    }
}

nonisolated extension SubtitleModel.Direction: Codable {}
nonisolated extension SubtitleModel.SessionMode: Codable {}
nonisolated extension SubtitleModel.CaptureScope: Codable {}
