import AppKit
import UniformTypeIdentifiers

/// Turns a session into a document someone can keep, send or print.
///
/// The one place a transcript is laid out as text: the clipboard copy, the
/// exported files and the history pane's copy all go through here, so a turn
/// reads the same wherever it ends up.
///
/// Every format writes the time of each turn, even when the board is hiding
/// it: on screen it is a density choice, but in a file the transcript has
/// lost the running session that made "when" obvious.
@MainActor
enum SessionExport {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        /// Readable as-is and renders cleanly in notes apps, wikis and chat.
        case markdown
        /// For anything that cannot be trusted with markup.
        case plainText
        /// For the reader who will open it in Word or Pages.
        case word

        var id: String { rawValue }

        var label: String { t("export.format.\(rawValue)") }

        var fileExtension: String {
            switch self {
            case .markdown: return "md"
            case .plainText: return "txt"
            case .word: return "docx"
            }
        }

        var contentType: UTType {
            UTType(filenameExtension: fileExtension) ?? .data
        }
    }

    /// The file's bytes in the given format.
    static func data(_ record: SessionRecord, format: Format) throws -> Data {
        switch format {
        case .markdown: return Data(markdown(record).utf8)
        case .plainText: return Data(plainText(record).utf8)
        case .word: return try word(record)
        }
    }

    /// A name that sorts by date in a folder and says what the file is.
    static func suggestedFileName(_ record: SessionRecord, format: Format) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let stamp = formatter.string(from: record.startedAt)
        return "\(t("export.documentTitle")) \(stamp).\(format.fileExtension)"
    }

    // MARK: - plain text

    /// The turns alone, as the clipboard carries them: a header line, then
    /// the source, then the translation, one blank line between turns.
    static func plainTurns(_ turns: [SessionRecord.Turn]) -> String {
        turns.map { turn in
            ["[\(timeLabel(turn.startedAt))] \(turn.direction.label)",
             turn.transcript, turn.translation]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    static func plainText(_ record: SessionRecord) -> String {
        let header = [title(record)] + metadata(record).map { t("export.meta.line", $0.0, $0.1) }
        return header.joined(separator: "\n") + "\n\n" + plainTurns(record.turns) + "\n"
    }

    // MARK: - markdown

    static func markdown(_ record: SessionRecord) -> String {
        var lines = ["# \(title(record))", ""]
        lines += metadata(record).map { "- " + t("export.meta.line", "**\($0.0)**", $0.1) }
        lines += ["", "---"]
        for turn in record.turns {
            lines += ["", "**\(timeLabel(turn.startedAt)) · \(turn.direction.label)**", ""]
            if !turn.transcript.isEmpty {
                lines.append(markdownParagraph(turn.transcript))
            }
            if !turn.translation.isEmpty {
                if !turn.transcript.isEmpty { lines.append("") }
                // The translation is quoted under its source, so the two read
                // as one turn and the pair is still told apart in plain view.
                lines.append(turn.translation
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "> " + markdownParagraph(String($0)) }
                    .joined(separator: "\n"))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Keeps a line from being read as markup it was never meant to be: a
    /// spoken "# 1" is not a heading, and "- " is not a list item.
    private static func markdownParagraph(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            guard let first = line.first, "#>-+*|".contains(first) else { return String(line) }
            return "\\" + line
        }
        .joined(separator: "  \n")
    }

    // MARK: - word

    private static func word(_ record: SessionRecord) throws -> Data {
        let document = NSMutableAttributedString()
        func font(_ size: CGFloat, bold: Bool = false) -> NSFont {
            let name = bold ? "HelveticaNeue-Bold" : "HelveticaNeue"
            return NSFont(name: name, size: size)
                ?? (bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size))
        }
        func paragraph(before: CGFloat, after: CGFloat) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = before
            style.paragraphSpacing = after
            style.lineHeightMultiple = 1.15
            return style
        }
        func append(_ text: String, _ attributes: [NSAttributedString.Key: Any]) {
            document.append(NSAttributedString(string: text + "\n", attributes: attributes))
        }
        let secondary = NSColor(white: 0.4, alpha: 1)
        // Word has no dark appearance; the lanes take their light values.
        let lanes: [SubtitleModel.Direction: NSColor] = [
            .remote: NSColor(red: 0.18, green: 0.43, blue: 0.40, alpha: 1),
            .local: NSColor(red: 0.11, green: 0.36, blue: 0.62, alpha: 1),
        ]

        append(title(record), [.font: font(20, bold: true),
                               .paragraphStyle: paragraph(before: 0, after: 8)])
        for (key, value) in metadata(record) {
            append(t("export.meta.line", key, value), [.font: font(10), .foregroundColor: secondary,
                                        .paragraphStyle: paragraph(before: 0, after: 2)])
        }
        for turn in record.turns {
            append("\(timeLabel(turn.startedAt))  \(turn.direction.label)", [
                .font: font(9.5, bold: true),
                .foregroundColor: lanes[turn.direction] ?? secondary,
                .paragraphStyle: paragraph(before: 14, after: 3),
            ])
            if !turn.transcript.isEmpty {
                append(turn.transcript, [.font: font(12),
                                         .paragraphStyle: paragraph(before: 0, after: 3)])
            }
            if !turn.translation.isEmpty {
                append(turn.translation, [.font: font(12), .foregroundColor: secondary,
                                          .paragraphStyle: paragraph(before: 0, after: 3)])
            }
        }
        return try document.data(
            from: NSRange(location: 0, length: document.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        )
    }

    // MARK: - shared parts

    static func title(_ record: SessionRecord) -> String {
        "\(t("export.documentTitle")) · "
            + record.startedAt.formatted(date: .abbreviated, time: .shortened)
    }

    /// The session's setup, as label–value pairs every format lays out its
    /// own way.
    static func metadata(_ record: SessionRecord) -> [(String, String)] {
        [
            (t("export.meta.time"), timeRange(record)),
            (t("subtitles.mode"), record.mode.label),
            (t("settings.translation.languages"), languagePair(record)),
            (t("subtitles.scope"), record.scope.label),
            (t("export.meta.turns"), "\(record.turns.count)"),
        ]
    }

    static func languagePair(_ record: SessionRecord) -> String {
        func name(_ code: String) -> String { Language.named(code)?.endonym ?? code }
        return "\(name(record.myLanguage)) ⇄ \(name(record.theirLanguage))"
    }

    static func timeRange(_ record: SessionRecord) -> String {
        let start = record.startedAt.formatted(date: .abbreviated, time: .shortened)
        let end = record.endedAt.formatted(date: .omitted, time: .shortened)
        return t("export.meta.timeRange", start, end, durationLabel(record.duration))
    }

    static func durationLabel(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = duration >= 3600 ? [.hour, .minute] : [.minute, .second]
        var calendar = Calendar.current
        calendar.locale = LocalizationStore.shared.language.locale
        formatter.calendar = calendar
        return formatter.string(from: max(duration, 0)) ?? ""
    }

    static func timeLabel(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())
    }
}
