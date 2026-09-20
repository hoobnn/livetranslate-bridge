import Foundation

/// The subset of the service's supported languages worth putting in a menu.
/// The full table is far longer; these are the ones a relay call plausibly
/// needs. See the model docs for the rest.
struct Language: Identifiable, Hashable, Sendable {
    let code: String
    var id: String { code }

    /// The language's name in its own script, which does not change with the
    /// interface language — the way macOS input-source menus label them.
    let endonym: String

    /// The name in the current interface language, for the Settings form
    /// where rows read as prose rather than as a picker of scripts.
    @MainActor
    var localizedName: String { t("language.\(code)") }

    /// Both, when the distinction is worth showing: 中文 / Chinese.
    @MainActor
    var menuLabel: String {
        localizedName == endonym ? endonym : "\(endonym) · \(localizedName)"
    }

    static let common: [Language] = [
        Language(code: "zh", endonym: "中文"),
        Language(code: "en", endonym: "English"),
        Language(code: "ja", endonym: "日本語"),
        Language(code: "ko", endonym: "한국어"),
        Language(code: "fr", endonym: "Français"),
        Language(code: "de", endonym: "Deutsch"),
        Language(code: "es", endonym: "Español"),
        Language(code: "ru", endonym: "Русский"),
    ]

    static func named(_ code: String) -> Language? {
        common.first { $0.code == code }
    }
}
