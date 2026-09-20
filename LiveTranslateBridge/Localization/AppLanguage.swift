import Foundation
import Observation
import SwiftUI

/// The in-app language switch.
///
/// The app ships Simplified Chinese and English and defaults to Chinese, which
/// is not what `Bundle.main` would pick on an English Mac. So rather than
/// letting the system resolve the language, the choice is explicit: it is
/// stored in defaults, and every localized string is looked up through the
/// bundle for that language (see `L10n`).
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case chinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    /// Shown in its own language, the way system language menus do it — a
    /// reader looking for their language should not need to read the current
    /// one first.
    var endonym: String {
        switch self {
        case .chinese: return "简体中文"
        case .english: return "English"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    /// The best match for the system's preferred languages, used only the
    /// first time the app runs. Chinese is the default: anything that is not
    /// recognizably English falls back to it.
    static var systemPreferred: AppLanguage {
        for identifier in Locale.preferredLanguages {
            let code = Locale(identifier: identifier).language.languageCode?.identifier
            if code == "en" { return .english }
            if code == "zh" { return .chinese }
        }
        return .chinese
    }
}

/// Holds the current language and hands out the matching `.lproj` bundle.
///
/// Changing the language republishes the whole view tree through the
/// environment, so the UI updates live rather than at the next launch.
@MainActor
@Observable
final class LocalizationStore {
    static let shared = LocalizationStore()

    private static let defaultsKey = "appLanguage"

    var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
            bundle = Self.bundle(for: language)
        }
    }

    /// The `.lproj` bundle strings are read from. Falls back to the main
    /// bundle if a language is somehow missing from the build.
    private(set) var bundle: Bundle

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey)
        let initial = stored.flatMap(AppLanguage.init(rawValue:))
            ?? AppLanguage.systemPreferred
        language = initial
        bundle = Self.bundle(for: initial)
    }

    private static func bundle(for language: AppLanguage) -> Bundle {
        guard let path = Bundle.main.path(forResource: language.rawValue,
                                          ofType: "lproj"),
              let bundle = Bundle(path: path)
        else { return .main }
        return bundle
    }
}

/// Looks up a localized string in the chosen language.
///
/// `LocalizedStringKey` resolves against `Bundle.main` and the *system*
/// language, which is exactly what the in-app switch overrides — so views ask
/// for `String`s through here instead.
@MainActor
enum L10n {
    static func callAsFunction(_ key: String) -> String {
        string(key)
    }

    static func string(_ key: String) -> String {
        LocalizationStore.shared.bundle.localizedString(
            forKey: key, value: key, table: nil
        )
    }

    static func string(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: LocalizationStore.shared.language.locale,
               arguments: arguments)
    }
}

/// Shorthand so call sites read as `t("subtitles.start")`.
@MainActor
func t(_ key: String) -> String { L10n.string(key) }

@MainActor
func t(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L10n.string(key),
           locale: LocalizationStore.shared.language.locale,
           arguments: arguments)
}

extension View {
    /// Applies the chosen language to everything below, so system-provided UI
    /// (date formats, the Settings window chrome) matches the app's own text.
    @MainActor
    func localized(_ store: LocalizationStore) -> some View {
        environment(\.locale, store.language.locale)
            .id(store.language)
    }
}
