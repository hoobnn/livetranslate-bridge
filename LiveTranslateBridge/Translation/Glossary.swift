import Foundation

/// The user's term list, sent as `translation.corpus.phrases`.
///
/// Written as one "source = target" pair per line so it can be typed or
/// pasted in a plain text field. Both directions receive the same list: the
/// service only applies a pair whose source term it actually hears, so a
/// Chinese term never fires on the English side and one list serves a call.
nonisolated enum Glossary {
    /// Accepted between the two halves, in this order of preference.
    private static let separators = ["=>", "→", "=", "\t"]

    static func parse(_ text: String) -> [String: String] {
        var phrases: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let separator = separators.first(where: trimmed.contains),
                  let range = trimmed.range(of: separator) else { continue }
            let source = trimmed[..<range.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            let target = trimmed[range.upperBound...]
                .trimmingCharacters(in: .whitespaces)
            guard !source.isEmpty, !target.isEmpty else { continue }
            phrases[source] = target
        }
        return phrases
    }
}
