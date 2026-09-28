import Foundation
import Testing
@testable import LiveTranslateBridge

@MainActor
struct SessionHistoryTests {
    private func turn(_ direction: SubtitleModel.Direction, _ transcript: String,
                      _ translation: String, at seconds: TimeInterval) -> SessionRecord.Turn {
        .init(direction: direction, startedAt: Date(timeIntervalSince1970: seconds),
              transcript: transcript, translation: translation)
    }

    private func sampleRecord() -> SessionRecord {
        SessionRecord(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_600),
            mode: .translate, scope: .both,
            myLanguage: "zh", theirLanguage: "en",
            turns: [
                turn(.remote, "# 1 is the plan", "第一是计划", at: 1_000),
                turn(.local, "好的", "Sure", at: 1_010),
            ]
        )
    }

    /// Feeds one complete translated utterance through the pre-3.8 path.
    private func say(_ model: SubtitleModel, _ transcript: String, _ translation: String,
                     from direction: SubtitleModel.Direction = .remote) {
        model.ingestForTesting(.transcriptComplete(transcript), from: direction)
        model.ingestForTesting(.translationComplete(translation), from: direction)
    }

    @Test func savedSessionsRoundTripThroughDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SessionHistoryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = SessionHistory(directory: directory)
        let record = sampleRecord()
        history.save(record, synchronously: true)

        #expect(SessionHistory.readAll(in: directory) == [record])

        history.delete(record.id)
        #expect(history.records.isEmpty)
    }

    /// A route change or a volume raised from zero restarts the sockets with
    /// the board preserved. That is the same session continuing, and must not
    /// split into two history entries; clearing the board is what starts a
    /// new one.
    @Test func internalRestartsKeepOneSessionAndClearingStartsAnother() {
        SubtitleModel.withTemporaryDefaults {
            let model = SubtitleModel()
            model.beginForTesting(preserveTranscript: false)
            say(model, "Hello", "你好")
            model.stop(preserveRouteWatcher: true)

            model.beginForTesting()
            say(model, "Again", "又见面了")
            model.stop()

            #expect(model.history.records.count == 1)
            #expect(model.history.records.first?.turns.map(\.transcript) == ["Hello", "Again"])

            model.clearEntries()
            model.beginForTesting()
            say(model, "Next", "下一个")
            model.stop()

            #expect(model.history.records.count == 2)
            #expect(model.history.records.map(\.turns.count).sorted() == [1, 2])
        }
    }

    @Test func nothingIsSavedWhenHistoryIsOff() {
        SubtitleModel.withTemporaryDefaults {
            let model = SubtitleModel()
            model.savesHistory = false
            model.beginForTesting(preserveTranscript: false)
            say(model, "Hello", "你好")
            model.stop()
            #expect(model.history.records.isEmpty)
            // Export does not depend on the history being kept.
            #expect(model.boardRecord?.turns.count == 1)
        }
    }

    /// A board no real session filled — a preview, a test feed — never
    /// reaches the history.
    @Test func boardsWithoutASessionAreNotSaved() {
        let model = SubtitleModel()
        say(model, "Hello", "你好")
        model.clearEntries()
        #expect(model.history.records.isEmpty)
    }

    @Test func markdownQuotesTranslationsAndEscapesSpokenMarkup() {
        let record = sampleRecord()
        let markdown = SessionExport.markdown(record)
        #expect(markdown.hasPrefix("# "))
        #expect(markdown.contains("\\# 1 is the plan"))
        #expect(markdown.contains("> 第一是计划"))
        #expect(markdown.contains("> Sure"))
    }

    @Test func plainTurnsMatchTheClipboardLayout() {
        let record = sampleRecord()
        let first = record.turns[0]
        let expected = "[\(SessionExport.timeLabel(first.startedAt))] "
            + "\(first.direction.label)\n# 1 is the plan\n第一是计划"
        #expect(SessionExport.plainTurns(record.turns).hasPrefix(expected + "\n\n"))
    }

    @Test func wordExportIsAnOfficeDocument() throws {
        let data = try SessionExport.data(sampleRecord(), format: .word)
        // .docx is a zip container.
        #expect(data.prefix(2) == Data("PK".utf8))
    }
}
