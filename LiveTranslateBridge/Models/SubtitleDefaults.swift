import Foundation

/// Where `SubtitleModel`'s options are stored between launches.
///
/// Split out of the model so the file that holds the utterance state machine
/// is not also the file that holds a dozen `UserDefaults` keys: the two change
/// for unrelated reasons, and the storage is the half that has to stay
/// bug-compatible with what older builds wrote.
///
/// Kept as a nested type rather than a free one so every use site in the model
/// still reads `Defaults.myLanguage` — the names in the model are unchanged by
/// the move.
extension SubtitleModel {
    /// The defaults keys behind the options above, with the fallbacks the
    /// first launch gets.
    /// Internal rather than private only because the model now lives in
    /// another file; nothing outside these two has any business here, and the
    /// keys stay private to the enum itself.
    enum Defaults {
        /// Both keep their original spellings so an existing install keeps the
        /// languages it already chose; only the names in code changed.
        private static let mineKey = "targetLanguage"
        private static let theirsKey = "sourceLanguage"
        private static let regionKey = "translationRegion"
        private static let deviceKey = "translationOutputDeviceUID"
        private static let inputKey = "uplinkInputDeviceUID"
        private static let cloneKey = "clonesVoice"
        private static let modeKey = "sessionMode"
        private static let scopeKey = "captureScope"
        private static let transcriptSizeKey = "transcriptSize"
        private static let timestampsKey = "showsTimestamps"
        private static let sourceTextKey = "showsSourceText"
        private static let sourceApplicationKey = "audioSourceBundleID"
        private static let remoteOutputKey = "remoteOutputDeviceUID"
        private static let remoteOriginalVolumeKey = "remoteOriginalVolume"
        private static let remoteTranslationVolumeKey = "remoteTranslationVolume"
        private static let localOriginalVolumeKey = "localOriginalVolume"
        private static let localTranslationVolumeKey = "localTranslationVolume"
        private static let silenceDurationKey = "segmentationSilenceMS"
        private static let vadThresholdKey = "segmentationThreshold"

        /// The pair a fresh install starts from: we speak Chinese, the far end
        /// English. Stated here rather than as literals at each use, so "what
        /// the app defaults to" is one fact in one place.
        static let initialMyLanguage = "zh"
        static let initialTheirLanguage = "en"

        /// Where the preferences are read and written. The app leaves this at
        /// the standard defaults; the tests point it at a throwaway suite, so
        /// that exercising the round trip cannot overwrite the settings of the
        /// real app on the same machine — which shares this bundle's domain.
        nonisolated(unsafe) static var store: UserDefaults = .standard

        static var myLanguage: String {
            get {
                let stored = store.string(forKey: mineKey)
                // A code dropped from `Language.common` between versions would
                // otherwise leave the picker with no selection.
                guard let stored, Language.named(stored) != nil else {
                    return initialMyLanguage
                }
                return stored
            }
            set { store.set(newValue, forKey: mineKey) }
        }

        static var theirLanguage: String {
            get {
                let stored = store.string(forKey: theirsKey) ?? ""
                // The two keys used to be independent — one of them accepted
                // "" for auto-detect — so a stored pair can be unusable in two
                // ways: missing, or equal to the other half. Both would leave
                // the app refusing to start with no visible cause, since there
                // is no longer a switch to turn the second direction off.
                // Resolve it here rather than making the user notice.
                guard Language.named(stored) != nil, stored != myLanguage else {
                    // Whichever half of the default pair the other side is not
                    // already using, so the fallback never collides.
                    return myLanguage == initialTheirLanguage
                        ? initialMyLanguage
                        : initialTheirLanguage
                }
                return stored
            }
            set { store.set(newValue, forKey: theirsKey) }
        }

        static var region: TranslationClient.Config.Region {
            get {
                store.string(forKey: regionKey)
                    .flatMap(TranslationClient.Config.Region.init(rawValue:))
                    ?? .beijing
            }
            set { store.set(newValue.rawValue, forKey: regionKey) }
        }

        static var outputDeviceUID: String {
            get { store.string(forKey: deviceKey) ?? "" }
            set { store.set(newValue, forKey: deviceKey) }
        }

        static var inputDeviceUID: String {
            get { store.string(forKey: inputKey) ?? "" }
            set { store.set(newValue, forKey: inputKey) }
        }

        static var sourceBundleID: String {
            get { store.string(forKey: sourceApplicationKey) ?? callAudioBundleID }
            set { store.set(newValue, forKey: sourceApplicationKey) }
        }

        /// Empty means follow the system default output. Unlike the local
        /// route, the remote route is always present while capturing because it
        /// also replays the original after the process tap mutes the source app.
        static var remoteOutputDeviceUID: String {
            get { store.string(forKey: remoteOutputKey) ?? "" }
            set { store.set(newValue, forKey: remoteOutputKey) }
        }

        static var ducksOriginal: Bool {
            get { store.bool(forKey: "ducksOriginal") }
            set { store.set(newValue, forKey: "ducksOriginal") }
        }

        static var remoteOriginalVolume: Double {
            get { storedVolume(remoteOriginalVolumeKey) }
            set { store.set(newValue, forKey: remoteOriginalVolumeKey) }
        }

        static var remoteTranslationVolume: Double {
            get { storedVolume(remoteTranslationVolumeKey) }
            set { store.set(newValue, forKey: remoteTranslationVolumeKey) }
        }

        static var localOriginalVolume: Double {
            get { storedVolume(localOriginalVolumeKey) }
            set { store.set(newValue, forKey: localOriginalVolumeKey) }
        }

        static var localTranslationVolume: Double {
            get { storedVolume(localTranslationVolumeKey) }
            set { store.set(newValue, forKey: localTranslationVolumeKey) }
        }

        /// How the service is asked to segment speech. Stored like the
        /// language pair: whoever tuned it once for their own calls is
        /// running the same kind of call next launch.
        ///
        /// Prefer sentence continuity by default; preserve explicit tuning.
        static var segmentation: TranslationClient.Config.Segmentation {
            get {
                let fallback = TranslationClient.Config.Segmentation.serviceDefault
                let silence = store.object(forKey: silenceDurationKey) as? Int
                    ?? fallback.silenceDuration
                let threshold = store.object(forKey: vadThresholdKey) as? Double
                    ?? fallback.threshold
                return .init(silenceDuration: silence, threshold: threshold)
            }
            set {
                store.set(newValue.silenceDuration, forKey: silenceDurationKey)
                store.set(newValue.threshold, forKey: vadThresholdKey)
            }
        }

        private static func storedVolume(_ key: String) -> Double {
            guard store.object(forKey: key) != nil else { return 1 }
            return min(max(store.double(forKey: key), 0), 2)
        }

        static var clonesVoice: Bool {
            get { store.bool(forKey: cloneKey) }
            set { store.set(newValue, forKey: cloneKey) }
        }

        /// Translation is the default: it is what the app is for, and an
        /// install that has never chosen should get the fuller behaviour.
        static var mode: SessionMode {
            get {
                store.string(forKey: modeKey)
                    .flatMap(SessionMode.init(rawValue:)) ?? .translate
            }
            set { store.set(newValue.rawValue, forKey: modeKey) }
        }

        /// Capturing both sides is the default, for the same reason.
        static var scope: CaptureScope {
            get {
                store.string(forKey: scopeKey)
                    .flatMap(CaptureScope.init(rawValue:)) ?? .both
            }
            set { store.set(newValue.rawValue, forKey: scopeKey) }
        }

        /// Medium is the size the board was designed at; the other three are
        /// departures from it in either direction.
        static var transcriptSize: TranscriptSize {
            get {
                store.string(forKey: transcriptSizeKey)
                    .flatMap(TranscriptSize.init(rawValue:)) ?? .medium
            }
            set { store.set(newValue.rawValue, forKey: transcriptSizeKey) }
        }

        /// Both default to on, and `bool(forKey:)` cannot express that: it
        /// answers false for a key nobody has written, which would turn them
        /// off on every fresh install. Storing them inverted would fix the
        /// default and break something worse — the stored value would then
        /// mean the opposite of its own key name, so an older build, a test or
        /// a `defaults write` touching the key would silently set the reverse.
        /// Asking whether the key exists keeps the stored `true` meaning on.
        static var showsTimestamps: Bool {
            get { store.object(forKey: timestampsKey) as? Bool ?? true }
            set { store.set(newValue, forKey: timestampsKey) }
        }

        static var showsSourceText: Bool {
            get { store.object(forKey: sourceTextKey) as? Bool ?? true }
            set { store.set(newValue, forKey: sourceTextKey) }
        }
    }
}
