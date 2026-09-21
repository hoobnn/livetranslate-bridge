//
//  SubtitleModelTests.swift
//  LiveTranslateBridgeTests
//
//  Created by haobin on 2026/9/20.
//

import Foundation
import Testing
@testable import LiveTranslateBridge

/// q3.8 streams both the transcript and the translation as true deltas
/// (`.transcriptDelta` / `.translationDelta`); the snapshot events
/// `.transcript` / `.translation` belong to the older models and replace
/// rather than append (see docs/findings.md §7). Confusing the two silently
/// doubles every subtitle, which is why the utterance state machine is worth
/// pinning down.
@MainActor
struct SubtitleEntryTests {

    @Test func longCallsKeepOnlyABoundedRenderedWorkingSet() {
        let model = SubtitleModel()
        for index in 0..<600 {
            model.ingestForTesting(.translationComplete("line-\(index)"))
        }

        #expect(model.entryCount == 600)
        #expect(model.entries.count == 500)
        #expect(model.visibleEntries.count == 250)
        #expect(model.transcriptText.contains("line-0"))
        #expect(model.transcriptText.contains("line-599"))
    }

    @Test func snapshotsReplaceRatherThanAppend() {
        let model = SubtitleModel()
        model.ingestForTesting(.translation("你好"))
        model.ingestForTesting(.translation("你好，请讲"))

        #expect(model.entries.count == 1)
        #expect(model.entries[0].translation == "你好，请讲")
    }

    @Test func deltasAppend() {
        let model = SubtitleModel()
        model.ingestForTesting(.translationDelta("Hello"))
        model.ingestForTesting(.translationDelta(", please go ahead"))

        #expect(model.entries[0].translation == "Hello, please go ahead")
    }

    @Test func transcriptDeltasAppend() {
        let model = SubtitleModel()
        model.ingestForTesting(.transcriptDelta("你好"))
        model.ingestForTesting(.transcriptDelta("，请讲"))

        #expect(model.entries.count == 1)
        #expect(model.entries[0].transcript == "你好，请讲")
    }

    /// The whole reason each utterance is sealed: with q3.8 both streams are
    /// deltas, so a missed seal would append the next utterance onto this one.
    @Test func transcriptDeltasDoNotBleedAcrossUtterances() {
        let model = SubtitleModel()
        model.ingestForTesting(.transcriptDelta("第一句"))
        model.ingestForTesting(.translationComplete("First"))
        model.ingestForTesting(.transcriptDelta("第二句"))

        #expect(model.entries.count == 2)
        #expect(model.entries[0].transcript == "第一句")
        #expect(model.entries[1].transcript == "第二句")
    }

    @Test func completionStartsANewUtterance() {
        let model = SubtitleModel()
        model.ingestForTesting(.transcript("第一句"))
        model.ingestForTesting(.translationComplete("First"))
        model.ingestForTesting(.transcript("第二句"))

        #expect(model.entries.count == 2)
        #expect(model.entries[0].isComplete)
        #expect(model.entries[0].transcript == "第一句")
        #expect(!model.entries[1].isComplete)
        #expect(model.entries[1].transcript == "第二句")
    }

    /// `session.finished` arrives after the last utterance is already sealed;
    /// it must not leave an empty card behind.
    @Test func finishingTwiceLeavesNoEmptyEntry() {
        let model = SubtitleModel()
        model.ingestForTesting(.translationComplete("Done"))
        model.ingestForTesting(.finished)

        #expect(model.entries.count == 1)
        #expect(model.entries[0].translation == "Done")
    }

    @Test func emptyCompletionIsDiscarded() {
        let model = SubtitleModel()
        model.ingestForTesting(.finished)

        #expect(model.entries.isEmpty)
    }
}

/// Both directions share one timeline, so the open utterance for a side is not
/// necessarily the last card on the board — the far end can start talking while
/// our own sentence is still streaming. Every one of these would pass with a
/// single-direction state machine and produce a board where the two speakers'
/// words are merged into each other.
@MainActor
struct BidirectionalEntryTests {

    @Test func eachDirectionGetsItsOwnEntry() {
        let model = SubtitleModel()
        model.ingestForTesting(.translationDelta("Hello"), from: .remote)
        model.ingestForTesting(.translationDelta("你好"), from: .local)

        #expect(model.entries.count == 2)
        #expect(model.entries[0].direction == .remote)
        #expect(model.entries[0].translation == "Hello")
        #expect(model.entries[1].direction == .local)
        #expect(model.entries[1].translation == "你好")
    }

    /// The interleaving case: a delta from one side must reach that side's own
    /// open entry, not whichever card happens to be last.
    @Test func interleavedDeltasStayInTheirOwnEntry() {
        let model = SubtitleModel()
        model.ingestForTesting(.translationDelta("How"), from: .remote)
        model.ingestForTesting(.translationDelta("我"), from: .local)
        model.ingestForTesting(.translationDelta(" are you"), from: .remote)
        model.ingestForTesting(.translationDelta("很好"), from: .local)

        #expect(model.entries.count == 2)
        #expect(model.entries[0].translation == "How are you")
        #expect(model.entries[1].translation == "我很好")
    }

    /// Sealing one side must leave the other side's in-progress utterance open.
    @Test func sealingOneDirectionLeavesTheOtherOpen() {
        let model = SubtitleModel()
        model.ingestForTesting(.translationDelta("Hi"), from: .remote)
        model.ingestForTesting(.translationDelta("你"), from: .local)
        model.ingestForTesting(.translationComplete("Hi there"), from: .remote)
        model.ingestForTesting(.translationDelta("好"), from: .local)

        #expect(model.entries.count == 2)
        #expect(model.entries[0].isComplete)
        #expect(model.entries[0].translation == "Hi there")
        #expect(!model.entries[1].isComplete)
        #expect(model.entries[1].translation == "你好")
    }

    /// `.finished` from one socket must not seal the other socket's utterance:
    /// the two sessions end independently.
    @Test func finishSealsOnlyItsOwnDirection() {
        let model = SubtitleModel()
        model.ingestForTesting(.translationDelta("Bye"), from: .remote)
        model.ingestForTesting(.translationDelta("再见"), from: .local)
        model.ingestForTesting(.finished, from: .remote)

        #expect(model.entries.count == 2)
        #expect(model.entries[0].isComplete)
        #expect(!model.entries[1].isComplete)
    }

    /// After both sides seal, each starts a fresh card rather than reopening
    /// the other's.
    @Test func newUtteranceAfterBothSealed() {
        let model = SubtitleModel()
        model.ingestForTesting(.translationComplete("One"), from: .remote)
        model.ingestForTesting(.translationComplete("一"), from: .local)
        model.ingestForTesting(.translationDelta("Two"), from: .remote)

        #expect(model.entries.count == 3)
        #expect(model.entries[2].direction == .remote)
        #expect(!model.entries[2].isComplete)
    }
}

/// Transcription runs the same pipeline with the target language dropped, so
/// what has to be pinned down is what *changes* when no translation arrives:
/// nothing seals the utterance unless the transcript does it.
@MainActor
struct TranscriptionModeTests {

    /// The whole reason `transcriptComplete` seals while transcribing. Without
    /// it no event ever closes the card, and every later utterance from that
    /// side appends onto the first one.
    @Test func transcriptCompletionSealsTheUtterance() {
        let model = SubtitleModel()
        model.ingestForTesting(.transcriptDelta("第一句"), mode: .transcribe)
        model.ingestForTesting(.transcriptComplete("第一句"), mode: .transcribe)
        model.ingestForTesting(.transcriptDelta("第二句"), mode: .transcribe)

        #expect(model.entries.count == 2)
        #expect(model.entries[0].isComplete)
        #expect(model.entries[0].transcript == "第一句")
        #expect(!model.entries[1].isComplete)
        #expect(model.entries[1].transcript == "第二句")
    }

    /// The mirror of the rule above: while translating, `transcriptComplete`
    /// arrives *before* the translation, so sealing on it would strand every
    /// translation in a card of its own with no source text.
    @Test func transcriptCompletionDoesNotSealWhileTranslating() {
        let model = SubtitleModel()
        model.ingestForTesting(.transcriptComplete("Hello"), mode: .translate)
        model.ingestForTesting(.translationComplete("你好"), mode: .translate)

        #expect(model.entries.count == 1)
        #expect(model.entries[0].transcript == "Hello")
        #expect(model.entries[0].translation == "你好")
        #expect(model.entries[0].isComplete)
    }

    /// Both sides are transcribed, and they interleave on one timeline exactly
    /// as they do when translating.
    @Test func bothDirectionsAreTranscribedIndependently() {
        let model = SubtitleModel()
        model.ingestForTesting(.transcriptDelta("Hello"), from: .remote, mode: .transcribe)
        model.ingestForTesting(.transcriptDelta("你好"), from: .local, mode: .transcribe)
        model.ingestForTesting(.transcriptComplete("Hello"), from: .remote, mode: .transcribe)
        model.ingestForTesting(.transcriptDelta("，请讲"), from: .local, mode: .transcribe)

        #expect(model.entries.count == 2)
        #expect(model.entries[0].direction == .remote)
        #expect(model.entries[0].isComplete)
        #expect(model.entries[1].direction == .local)
        #expect(!model.entries[1].isComplete)
        #expect(model.entries[1].transcript == "你好，请讲")
    }

    /// Nothing fills the translation field, so a transcribed board copies as
    /// one line per utterance rather than leaving blank gaps.
    @Test func transcribedEntriesCarryNoTranslation() {
        let model = SubtitleModel()
        model.ingestForTesting(.transcriptComplete("Hello"), mode: .transcribe)

        #expect(model.entries[0].translation.isEmpty)
        #expect(model.transcriptText.contains("Hello"))
    }
}

/// Transcription has nothing to translate into, so the preconditions and the
/// derived switches that exist to protect translation have to stand down.
@MainActor
@Suite(.serialized)
struct TranscriptionModeSettingsTests {

    private func withIsolatedDefaults(_ body: () -> Void) {
        SubtitleModel.withTemporaryDefaults(body)
    }

    /// A call between two speakers of one language is the ordinary case for
    /// transcription, and the pair must be allowed to say so.
    @Test func bothSidesMaySpeakTheSameLanguageWhenTranscribing() {
        withIsolatedDefaults {
            let model = SubtitleModel()
            model.mode = .transcribe
            model.theirLanguage = model.myLanguage

            #expect(model.myLanguage == model.theirLanguage)
            #expect(model.hasUsableLanguagePair)
        }
    }

    /// The collision rule still protects translation, which cannot run on a
    /// pair that does not differ.
    @Test func translatingStillRefusesACollapsedPair() {
        withIsolatedDefaults {
            let model = SubtitleModel()
            model.mode = .translate
            model.theirLanguage = model.myLanguage

            #expect(model.myLanguage != model.theirLanguage)
            #expect(model.hasUsableLanguagePair)
        }
    }

    /// Switching to transcription must not quietly discard the pair: it is
    /// still pinning ASR, and it is still there on the way back.
    @Test func thePairSurvivesAModeSwitch() {
        withIsolatedDefaults {
            let model = SubtitleModel()
            model.myLanguage = "ja"
            model.theirLanguage = "ko"
            model.mode = .transcribe

            #expect(model.myLanguage == "ja")
            #expect(model.theirLanguage == "ko")

            model.mode = .translate
            #expect(model.myLanguage == "ja")
            #expect(model.theirLanguage == "ko")
        }
    }

    /// There is no translation to speak, so a device chosen for translation
    /// must not cause speech while transcribing — and must not be forgotten
    /// either.
    @Test func transcriptionNeverSpeaks() {
        withIsolatedDefaults {
            let model = SubtitleModel()
            model.outputDeviceUID = "BlackHole2ch_UID"
            #expect(model.speaksTranslation)

            model.mode = .transcribe
            #expect(!model.speaksTranslation)
            #expect(model.outputDeviceUID == "BlackHole2ch_UID")

            model.mode = .translate
            #expect(model.speaksTranslation)
        }
    }

    /// Transcription permits a pair translation cannot run on, so the return
    /// trip has to repair it — otherwise Start fails with an error the user
    /// cannot clear without tripping the collision rule on the way.
    @Test func returningToTranslationRepairsACollapsedPair() {
        withIsolatedDefaults {
            let model = SubtitleModel()
            model.mode = .transcribe
            model.myLanguage = "ja"
            model.theirLanguage = "ja"
            #expect(model.hasUsableLanguagePair)

            model.mode = .translate

            #expect(model.myLanguage == "ja")
            #expect(model.myLanguage != model.theirLanguage)
            #expect(model.hasUsableLanguagePair)
        }
    }

    @Test func theModeSurvivesANewModel() {
        withIsolatedDefaults {
            let first = SubtitleModel()
            first.mode = .transcribe

            #expect(SubtitleModel().mode == .transcribe)
        }
    }

    @Test func aFreshInstallDefaultsToTranslating() {
        withIsolatedDefaults {
            #expect(SubtitleModel().mode == .translate)
        }
    }
}

/// Capturing one side is not the two-sided pipeline with a socket switched
/// off: only the tap needs a call, so the microphone alone changes what the
/// session waits for and what the status can ever say.
@MainActor
@Suite(.serialized)
struct CaptureScopeTests {

    private func withIsolatedDefaults(_ body: () -> Void) {
        SubtitleModel.withTemporaryDefaults(body)
    }

    @Test func bothSidesAreCapturedByDefault() {
        withIsolatedDefaults {
            let model = SubtitleModel()
            #expect(model.scope == .both)
            #expect(model.scope.captures(.remote))
            #expect(model.scope.captures(.local))
        }
    }

    @Test func eachScopeCapturesOnlyItsOwnSides() {
        #expect(SubtitleModel.CaptureScope.remoteOnly.captures(.remote))
        #expect(!SubtitleModel.CaptureScope.remoteOnly.captures(.local))
        #expect(SubtitleModel.CaptureScope.localOnly.captures(.local))
        #expect(!SubtitleModel.CaptureScope.localOnly.captures(.remote))
    }

    /// The distinction the whole feature turns on: a tap needs a call, a
    /// microphone does not.
    @Test func onlyTheMicrophoneRunsWithoutACall() {
        #expect(SubtitleModel.CaptureScope.both.needsCall)
        #expect(SubtitleModel.CaptureScope.remoteOnly.needsCall)
        #expect(!SubtitleModel.CaptureScope.localOnly.needsCall)
    }

    /// Nothing of ours is captured, so there is nothing of ours to synthesise
    /// — but the device the user chose is not thrown away.
    @Test func capturingTheFarEndAloneNeverSpeaks() {
        withIsolatedDefaults {
            let model = SubtitleModel()
            model.outputDeviceUID = "BlackHole2ch_UID"
            #expect(model.speaksTranslation)

            model.scope = .remoteOnly
            #expect(!model.speaksTranslation)
            #expect(model.outputDeviceUID == "BlackHole2ch_UID")

            model.scope = .both
            #expect(model.speaksTranslation)
        }
    }

    /// Our own side is captured here, so the choice to speak still stands.
    @Test func capturingOurOwnSideAloneStillSpeaks() {
        withIsolatedDefaults {
            let model = SubtitleModel()
            model.outputDeviceUID = "BlackHole2ch_UID"
            model.scope = .localOnly

            #expect(model.speaksTranslation)
        }
    }

    @Test func theScopeSurvivesANewModel() {
        withIsolatedDefaults {
            SubtitleModel().scope = .localOnly
            #expect(SubtitleModel().scope == .localOnly)
        }
    }

    /// The scope is orthogonal to the mode: either combination is legal and
    /// neither rewrites the other.
    @Test func scopeAndModeAreIndependent() {
        withIsolatedDefaults {
            let model = SubtitleModel()
            model.scope = .localOnly
            model.mode = .transcribe

            #expect(model.scope == .localOnly)
            #expect(model.mode == .transcribe)
            #expect(!model.speaksTranslation)
        }
    }

    /// The bug this guards: `sessionReady` used to announce "waiting for a
    /// call" unconditionally. Capturing our own side alone never gets a call,
    /// so that status would have stayed on screen for the whole session while
    /// audio was in fact flowing.
    @Test func theMicrophoneAloneRunsAsSoonAsTheSocketIsUp() {
        let model = SubtitleModel()
        model.beginForTesting(scope: .localOnly)
        model.ingestForTesting(.sessionReady, from: .local, scope: .localOnly)

        #expect(model.status == .running)
    }

    /// The tap does wait, and must go on saying so.
    @Test func aTappedSessionStillWaitsForTheCall() {
        let model = SubtitleModel()
        model.beginForTesting(scope: .both)
        model.ingestForTesting(.sessionReady, scope: .both)

        #expect(model.status == .waitingForCall)
    }

    /// An idle call-state arriving from the monitor must not knock a
    /// microphone-only session back into waiting either.
    @Test func anIdleCallDoesNotStallTheMicrophoneAlone() {
        let model = SubtitleModel()
        model.beginForTesting(scope: .localOnly)
        model.applyForTesting(callState: .idle)

        #expect(model.status == .running)
    }

    @Test func anIdleCallStillStallsATappedSession() {
        let model = SubtitleModel()
        model.beginForTesting(scope: .remoteOnly)
        model.applyForTesting(callState: .idle)

        #expect(model.status == .waitingForCall)
    }

    /// A single-sided scope still translates between two languages — the
    /// source and the target are both needed, so the pair rule is unchanged.
    @Test func translatingOneSideStillNeedsTwoLanguages() {
        withIsolatedDefaults {
            let model = SubtitleModel()
            model.scope = .remoteOnly
            model.theirLanguage = model.myLanguage

            #expect(model.myLanguage != model.theirLanguage)
            #expect(model.hasUsableLanguagePair)
        }
    }
}

/// The language pair is now the app's entire setup, so the invariants that
/// used to be spread across toggles live on it instead.
// Serialized: these swap the shared defaults store, so running two of
// them at once would leave each reading the other's suite.
@MainActor
@Suite(.serialized)
struct LanguagePairTests {

    /// The app under test shares its defaults domain with the real app on this
    /// machine, so a case that sets a language would otherwise leave the
    /// developer's own copy holding it. Each runs against a throwaway suite.
    private func withIsolatedDefaults(_ body: () -> Void) {
        SubtitleModel.withTemporaryDefaults(body)
    }

    @Test func defaultsAreAUsablePair() {
        withIsolatedDefaults {
            let model = SubtitleModel()
            // Whatever an existing install stored — including the empty string the
            // retired auto-detect option used to write — the pair must come up
            // usable, since there is no longer a switch to turn the second
            // direction off if it does not.
            #expect(!model.myLanguage.isEmpty)
            #expect(!model.theirLanguage.isEmpty)
            #expect(model.hasUsableLanguagePair)
        }
    }

    /// Assigning one side the other's language cannot collapse the pair: the
    /// setters swap instead, so `hasUsableLanguagePair` stays true. The guard
    /// itself remains as the last line of defence for a pair restored from
    /// defaults written by an older build.
    @Test func thePairCannotCollapseThroughTheSetters() {
        withIsolatedDefaults {
            let model = SubtitleModel()
            model.theirLanguage = model.myLanguage

            #expect(model.hasUsableLanguagePair)
            #expect(model.myLanguage != model.theirLanguage)
        }
    }

    /// Speech is derived from the device choice rather than stored separately,
    /// so the two can never disagree.
    @Test func speechFollowsTheChosenDevice() {
        withIsolatedDefaults {
            let model = SubtitleModel()
            model.outputDeviceUID = ""
            #expect(!model.speaksTranslation)

            model.outputDeviceUID = "SomeLoopbackUID"
            #expect(model.speaksTranslation)
        }
    }
}

/// Choosing the language the other side already holds swaps the pair instead of
/// collapsing it. Without this the UI can reach a state the session refuses to
/// start from, with nothing on screen explaining why.
// Serialized: these swap the shared defaults store, so running two of
// them at once would leave each reading the other's suite.
@MainActor
@Suite(.serialized)
struct LanguageSwapTests {

    /// The app under test shares its defaults domain with the real app on this
    /// machine, so a case that sets a language would otherwise leave the
    /// developer's own copy holding it. Each runs against a throwaway suite.
    private func withIsolatedDefaults(_ body: () -> Void) {
        SubtitleModel.withTemporaryDefaults(body)
    }

    @Test func choosingTheirLanguageForMyselfSwapsThePair() {
        withIsolatedDefaults {
            let model = SubtitleModel()
            model.myLanguage = "zh"
            model.theirLanguage = "ja"

            model.myLanguage = "ja"

            #expect(model.myLanguage == "ja")
            #expect(model.theirLanguage == "zh")
            #expect(model.hasUsableLanguagePair)
        }
    }

    @Test func choosingMyLanguageForThemSwapsThePair() {
        withIsolatedDefaults {
            let model = SubtitleModel()
            model.myLanguage = "zh"
            model.theirLanguage = "ja"

            model.theirLanguage = "zh"

            #expect(model.theirLanguage == "zh")
            #expect(model.myLanguage == "ja")
            #expect(model.hasUsableLanguagePair)
        }
    }

    /// The swap button in the header goes through `swapLanguages()`, which
    /// suspends the collapse guard — done as two plain assignments the
    /// intermediate state collides and the guard rewrites the result.
    @Test func explicitSwapKeepsBothLanguages() {
        withIsolatedDefaults {
            let model = SubtitleModel()
            model.myLanguage = "zh"
            model.theirLanguage = "en"

            model.swapLanguages()

            #expect(model.myLanguage == "en")
            #expect(model.theirLanguage == "zh")
        }
    }

    /// Swapping a non-default pair must not quietly pull either side towards
    /// the default one.
    @Test func swapIsSymmetricForAnyPair() {
        withIsolatedDefaults {
            let model = SubtitleModel()
            model.myLanguage = "ja"
            model.theirLanguage = "ko"

            model.swapLanguages()

            #expect(model.myLanguage == "ko")
            #expect(model.theirLanguage == "ja")
        }
    }

    /// Swapping twice is the identity — the guard must not leak a rewrite into
    /// either half of the round trip.
    @Test func swappingTwiceRestoresTheOriginalPair() {
        withIsolatedDefaults {
            let model = SubtitleModel()
            model.myLanguage = "fr"
            model.theirLanguage = "de"

            model.swapLanguages()
            model.swapLanguages()

            #expect(model.myLanguage == "fr")
            #expect(model.theirLanguage == "de")
        }
    }
}

/// The pair is a stored preference, so the contract is not only that a setter
/// works but that what it wrote is what the next launch reads back. These
/// exercise the defaults round trip, which is where the pair was being lost.
// Serialized: these swap the shared defaults store, so running two of
// them at once would leave each reading the other's suite.
@MainActor
@Suite(.serialized)
struct LanguagePersistenceTests {

    /// The app under test shares its defaults domain with the real app on this
    /// machine, so writing the live preferences would leave the developer's own
    /// copy holding whatever the last case picked. Every case runs against a
    /// throwaway suite instead.
    private func withRestoredDefaults(_ body: () -> Void) {
        SubtitleModel.withTemporaryDefaults(body)
    }

    /// The bug this covers: the pair was written to defaults, so a launch
    /// faithfully restored whatever the last edit left behind — including a
    /// pair the user never chose.
    @Test func aChosenPairSurvivesANewModel() {
        withRestoredDefaults {
            let first = SubtitleModel()
            first.myLanguage = "zh"
            first.theirLanguage = "en"

            let second = SubtitleModel()
            #expect(second.myLanguage == "zh")
            #expect(second.theirLanguage == "en")
        }
    }

    @Test func aNonDefaultPairAlsoSurvives() {
        withRestoredDefaults {
            let first = SubtitleModel()
            first.myLanguage = "ja"
            first.theirLanguage = "ko"

            let second = SubtitleModel()
            #expect(second.myLanguage == "ja")
            #expect(second.theirLanguage == "ko")
        }
    }

    /// A swap is an edit like any other and has to outlive the launch too.
    @Test func aSwappedPairSurvives() {
        withRestoredDefaults {
            let first = SubtitleModel()
            first.myLanguage = "zh"
            first.theirLanguage = "en"
            first.swapLanguages()

            let second = SubtitleModel()
            #expect(second.myLanguage == "en")
            #expect(second.theirLanguage == "zh")
        }
    }

    /// The recovery path for an install whose stored pair is wrong: reset puts
    /// both sides back at once, which picking them one at a time cannot do
    /// because the half-edited state trips the collapse guard.
    @Test func resetRestoresTheDefaultPairAndPersistsIt() {
        withRestoredDefaults {
            let first = SubtitleModel()
            first.myLanguage = "ja"
            first.theirLanguage = "ko"

            first.resetLanguagesToDefault()
            #expect(first.myLanguage == "zh")
            #expect(first.theirLanguage == "en")
            #expect(first.usesDefaultLanguagePair)

            let second = SubtitleModel()
            #expect(second.myLanguage == "zh")
            #expect(second.theirLanguage == "en")
        }
    }

    /// Exactly the state the reported install was stuck in: "I speak Japanese,
    /// they speak Chinese". Reset has to reach zh/en from there in one step.
    @Test func resetRecoversTheReportedStuckPair() {
        withRestoredDefaults {
            SubtitleModel.defaultsStoreForTesting.set("ja", forKey: "targetLanguage")
            SubtitleModel.defaultsStoreForTesting.set("zh", forKey: "sourceLanguage")

            let model = SubtitleModel()
            #expect(model.myLanguage == "ja")
            #expect(model.theirLanguage == "zh")

            model.resetLanguagesToDefault()
            #expect(model.myLanguage == "zh")
            #expect(model.theirLanguage == "en")
        }
    }

    /// A fresh install, with nothing stored, must come up as Chinese/English
    /// rather than following the system or whatever the picker lists first.
    @Test func aFreshInstallDefaultsToChineseAndEnglish() {
        withRestoredDefaults {
            SubtitleModel.defaultsStoreForTesting.removeObject(forKey: "targetLanguage")
            SubtitleModel.defaultsStoreForTesting.removeObject(forKey: "sourceLanguage")

            let model = SubtitleModel()
            #expect(model.myLanguage == "zh")
            #expect(model.theirLanguage == "en")
            #expect(model.usesDefaultLanguagePair)
        }
    }

    /// Defaults written by an older build could hold "" for auto-detect, or the
    /// same language on both sides. Either way the pair has to come up usable.
    @Test func anUnusableStoredPairIsRepairedOnLoad() {
        withRestoredDefaults {
            SubtitleModel.defaultsStoreForTesting.set("zh", forKey: "targetLanguage")
            SubtitleModel.defaultsStoreForTesting.set("", forKey: "sourceLanguage")

            let model = SubtitleModel()
            #expect(model.hasUsableLanguagePair)
            #expect(model.myLanguage == "zh")
            #expect(model.theirLanguage == "en")
        }
    }

    @Test func aCollidingStoredPairIsRepairedOnLoad() {
        withRestoredDefaults {
            SubtitleModel.defaultsStoreForTesting.set("ja", forKey: "targetLanguage")
            SubtitleModel.defaultsStoreForTesting.set("ja", forKey: "sourceLanguage")

            let model = SubtitleModel()
            #expect(model.hasUsableLanguagePair)
            #expect(model.myLanguage == "ja")
        }
    }
}

/// The other stored options. Each is a separate defaults key, and each was
/// worth checking rather than assumed — the language pair persisted too, and
/// still came back wrong.
// Serialized: these swap the shared defaults store, so running two of
// them at once would leave each reading the other's suite.
@MainActor
@Suite(.serialized)
struct OtherPreferencePersistenceTests {

    private func withRestoredDefaults(_ body: () -> Void) {
        SubtitleModel.withTemporaryDefaults(body)
    }

    @Test func theAudioSourceDefaultsToContinuityAndPersistsAReplacement() {
        withRestoredDefaults {
            let first = SubtitleModel()
            #expect(first.sourceBundleID == callAudioBundleID)

            first.sourceBundleID = "com.example.conference"
            #expect(SubtitleModel().sourceBundleID == "com.example.conference")
        }
    }

    @Test func routeDevicesAndVolumesSurviveANewModel() {
        withRestoredDefaults {
            let first = SubtitleModel()
            first.remoteOutputDeviceUID = "SpeakerUID"
            first.remoteOriginalVolume = 0.35
            first.remoteTranslationVolume = 1.25
            first.localOriginalVolume = 0.7
            first.localTranslationVolume = 1.5

            let second = SubtitleModel()
            #expect(second.remoteOutputDeviceUID == "SpeakerUID")
            #expect(second.remoteOriginalVolume == 0.35)
            #expect(second.remoteTranslationVolume == 1.25)
            #expect(second.localOriginalVolume == 0.7)
            #expect(second.localTranslationVolume == 1.5)
        }
    }

    @Test func zeroTranslationGainDisablesModelAudioPerDirection() {
        withRestoredDefaults {
            let model = SubtitleModel()
            model.outputDeviceUID = "LoopbackUID"
            model.remoteTranslationVolume = 0
            model.localTranslationVolume = 0

            #expect(!model.speaksRemoteTranslation)
            #expect(!model.speaksTranslation)
        }
    }

    @Test func theOutputDeviceSurvivesANewModel() {
        withRestoredDefaults {
            let first = SubtitleModel()
            first.outputDeviceUID = "SomeLoopbackUID"

            let second = SubtitleModel()
            #expect(second.outputDeviceUID == "SomeLoopbackUID")
            #expect(second.speaksTranslation)
        }
    }

    @Test func turningSpeechOffSurvivesANewModel() {
        withRestoredDefaults {
            let first = SubtitleModel()
            first.outputDeviceUID = ""

            let second = SubtitleModel()
            #expect(second.outputDeviceUID.isEmpty)
            #expect(!second.speaksTranslation)
        }
    }

    @Test func theVoiceCloneToggleSurvivesANewModel() {
        withRestoredDefaults {
            let first = SubtitleModel()
            first.clonesVoice = true
            #expect(SubtitleModel().clonesVoice)

            first.clonesVoice = false
            #expect(!SubtitleModel().clonesVoice)
        }
    }

    @Test func theRegionSurvivesANewModel() {
        withRestoredDefaults {
            let first = SubtitleModel()
            first.region = .singapore
            #expect(SubtitleModel().region == .singapore)

            first.region = .beijing
            #expect(SubtitleModel().region == .beijing)
        }
    }

    /// Nothing stored means Beijing, which is the region the credentials in the
    /// README are issued for.
    @Test func theRegionDefaultsToBeijing() {
        withRestoredDefaults {
            SubtitleModel.defaultsStoreForTesting.removeObject(forKey: "translationRegion")
            #expect(SubtitleModel().region == .beijing)
        }
    }
}

/// The interface language is stored separately from the translation options,
/// through its own singleton, so it gets its own round trip.
// Serialized: these swap the shared defaults store, so running two of
// them at once would leave each reading the other's suite.
@MainActor
@Suite(.serialized)
struct InterfaceLanguagePersistenceTests {

    @Test func theChosenInterfaceLanguageIsWrittenToDefaults() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "appLanguage")
        defer { defaults.set(saved, forKey: "appLanguage") }

        let store = LocalizationStore.shared
        let original = store.language
        defer { store.language = original }

        store.language = .english
        #expect(defaults.string(forKey: "appLanguage") == "en")

        store.language = .chinese
        #expect(defaults.string(forKey: "appLanguage") == "zh-Hans")
    }
}

/// The reading preferences: text size, timestamps and whether the source line
/// is kept under a translation.
///
/// Worth pinning because two of the three default to *on*, which
/// `bool(forKey:)` cannot express — it answers false for a key nobody has
/// written, and reading it directly would turn them both off on every fresh
/// install. The first implementation here stored them inverted to dodge that
/// and produced a worse bug: a stored `true` then meant "off", so a key written
/// by anything else read backwards. These tests cover both halves.
// Serialized: these swap the shared defaults store, so running two of
// them at once would leave each reading the other's suite.
@MainActor
@Suite(.serialized)
struct DisplayPreferenceTests {

    private func withIsolatedDefaults(_ body: () -> Void) {
        SubtitleModel.withTemporaryDefaults(body)
    }

    @Test func aFreshInstallShowsTimestampsAndSourceText() {
        withIsolatedDefaults {
            let model = SubtitleModel()

            #expect(model.showsTimestamps)
            #expect(model.showsSourceText)
        }
    }

    /// Medium is the size the board was designed at.
    @Test func aFreshInstallReadsAtTheMediumSize() {
        withIsolatedDefaults {
            #expect(SubtitleModel().transcriptSize == .medium)
        }
    }

    @Test func eachPreferenceSurvivesANewModel() {
        withIsolatedDefaults {
            let first = SubtitleModel()
            first.transcriptSize = .extraLarge
            first.showsTimestamps = false
            first.showsSourceText = false

            let second = SubtitleModel()
            #expect(second.transcriptSize == .extraLarge)
            #expect(!second.showsTimestamps)
            #expect(!second.showsSourceText)
        }
    }

    /// Switching a toggle off and back on has to land on the default again,
    /// which is the round trip the inverted storage could break in one
    /// direction only.
    @Test func togglingBackOnIsStoredAsOn() {
        withIsolatedDefaults {
            let first = SubtitleModel()
            first.showsTimestamps = false
            first.showsTimestamps = true

            #expect(SubtitleModel().showsTimestamps)
        }
    }

    /// A stored value has to mean what its key says, so that a `true` written
    /// by an older build, a test, or `defaults write` reads as *on*. This is
    /// the regression the inverted storage caused: it showed up as timestamps
    /// silently disabled on a board whose preference read as enabled.
    @Test func aStoredTrueMeansOn() {
        withIsolatedDefaults {
            let store = SubtitleModel.defaultsStoreForTesting
            store.set(true, forKey: "showsTimestamps")
            store.set(true, forKey: "showsSourceText")

            let model = SubtitleModel()
            #expect(model.showsTimestamps)
            #expect(model.showsSourceText)
        }
    }

    @Test func aStoredFalseMeansOff() {
        withIsolatedDefaults {
            let store = SubtitleModel.defaultsStoreForTesting
            store.set(false, forKey: "showsTimestamps")
            store.set(false, forKey: "showsSourceText")

            let model = SubtitleModel()
            #expect(!model.showsTimestamps)
            #expect(!model.showsSourceText)
        }
    }

    /// The sizes have to be strictly increasing, or the picker offers two
    /// options that draw the same board.
    @Test func theSizesIncrease() {
        let sizes = SubtitleModel.TranscriptSize.allCases
        for (smaller, larger) in zip(sizes, sizes.dropFirst()) {
            #expect(smaller.primary < larger.primary)
            #expect(smaller.secondary < larger.secondary)
            // The source line never outgrows the line it sits under.
            #expect(smaller.secondary < smaller.primary)
        }
    }
}

/// The board carries the time each utterance began, and the copy button puts
/// it on the clipboard whether or not the board is currently showing it.
@MainActor
struct TranscriptTimestampTests {

    @Test func everyEntryCarriesAStartTime() {
        let model = SubtitleModel()
        let before = Date.now
        model.ingestForTesting(.transcriptDelta("你好"))

        let started = model.entries[0].startedAt
        #expect(started >= before)
        #expect(started <= .now)
    }

    /// The time is pinned when the utterance opens, not when it closes, so a
    /// long sentence is filed under when the speaker started it.
    @Test func theTimeDoesNotMoveWhileTheUtteranceStreams() {
        let model = SubtitleModel()
        model.ingestForTesting(.transcriptDelta("Hello"))
        let opened = model.entries[0].startedAt

        model.ingestForTesting(.transcriptDelta(", please go ahead"))
        model.ingestForTesting(.translationComplete("你好，请讲"))

        #expect(model.entries[0].startedAt == opened)
    }

    /// Pasted into notes, a transcript has lost the running session that made
    /// "when" obvious — so the copied text carries the time even though the
    /// board treats showing it as a density choice.
    @Test func copiedTextCarriesTheTimeAndTheSpeaker() {
        let model = SubtitleModel()
        model.showsTimestamps = false
        model.ingestForTesting(.transcriptComplete("Hello"), from: .remote)
        model.ingestForTesting(.translationComplete("你好"), from: .remote)

        let text = model.transcriptText
        #expect(text.contains(model.entries[0].timeLabel))
        #expect(text.contains(SubtitleModel.Direction.remote.label))
        #expect(text.contains("Hello"))
        #expect(text.contains("你好"))
    }
}

// MARK: - run grouping

/// The board drops a card's header when the card above it came from the same
/// side, and gives air to one that opens a new speaker's run. Both facts used
/// to be re-derived in the view from a neighbouring index on every redraw;
/// they are now carried on the entry and written where the board grows.
///
/// That move is only safe if the flags stay true through the two things that
/// change what sits above a card: a new utterance arriving, and an empty one
/// being dropped when it seals. These cover both — with the flags wrong the
/// app still runs and still says the right words, it just groups a
/// conversation that never happened.
@MainActor
struct RunGroupingTests {

    /// The first card starts no *new* run, so it takes neither the header
    /// suppression nor the leading gap.
    @Test func theFirstCardOpensNothing() {
        let model = SubtitleModel()
        model.ingestForTesting(.transcriptDelta("Hello"), from: .remote)

        #expect(!model.entries[0].continuesRun)
        #expect(!model.entries[0].startsNewSpeaker)
    }

    /// Two turns from one side: the second continues the run and drops its
    /// header.
    @Test func aSecondTurnFromTheSameSideContinuesTheRun() {
        let model = SubtitleModel()
        model.ingestForTesting(.translationComplete("One"), from: .remote)
        model.ingestForTesting(.translationDelta("Two"), from: .remote)

        #expect(model.entries.count == 2)
        #expect(model.entries[1].continuesRun)
        #expect(!model.entries[1].startsNewSpeaker)
    }

    /// A turn from the other side breaks the run and takes the gap.
    @Test func theOtherSideStartsANewRun() {
        let model = SubtitleModel()
        model.ingestForTesting(.translationComplete("One"), from: .remote)
        model.ingestForTesting(.translationDelta("一"), from: .local)

        #expect(model.entries.count == 2)
        #expect(!model.entries[1].continuesRun)
        #expect(model.entries[1].startsNewSpeaker)
    }

    /// The case the stored flags could get wrong and the derived ones could
    /// not: an utterance that closes with nothing in it is dropped from the
    /// board, which hands the card below it a different neighbour.
    ///
    /// Here a remote card is followed by an empty local one and then another
    /// remote. Once the empty card goes, the last card follows a card from
    /// its own side — so it continues that run rather than opening one.
    @Test func droppingAnEmptyUtteranceRepairsTheCardBelowIt() {
        let model = SubtitleModel()
        model.ingestForTesting(.translationComplete("One"), from: .remote)
        // Opens a local entry and seals it while still empty, so it is
        // removed rather than kept.
        model.ingestForTesting(.speechStarted, from: .local)
        model.ingestForTesting(.translationDelta(""), from: .local)
        model.ingestForTesting(.finished, from: .local)
        model.ingestForTesting(.translationDelta("Two"), from: .remote)

        // The empty local card left no trace.
        #expect(model.entries.count == 2)
        #expect(model.entries.allSatisfy { $0.direction == .remote })
        // And the survivor below it groups against what actually precedes it.
        #expect(model.entries[1].continuesRun)
        #expect(!model.entries[1].startsNewSpeaker)
    }

    /// The flags a long alternating board ends up with must match what a
    /// straight read of the finished board says they should be — the property
    /// the view used to compute for itself.
    @Test func flagsAgreeWithTheFinishedBoard() {
        let model = SubtitleModel()
        let script: [(SubtitleModel.Direction, String)] = [
            (.remote, "a"), (.remote, "b"), (.local, "c"),
            (.local, "d"), (.remote, "e"), (.local, "f"),
        ]
        for (direction, text) in script {
            model.ingestForTesting(.translationComplete(text), from: direction)
        }

        #expect(model.entries.count == script.count)
        for index in model.entries.indices {
            let expected = index > 0
                && model.entries[index - 1].direction == model.entries[index].direction
            #expect(model.entries[index].continuesRun == expected)
            #expect(model.entries[index].startsNewSpeaker == (index > 0 && !expected))
        }
    }
}

// MARK: - surviving a dropped socket

/// A call has quiet stretches, and the service closes a session that has gone
/// quiet. Before reconnecting, that ended the subtitles for the rest of the
/// call while the app went on claiming to run: capture still worked, buffers
/// still converted, and every one of them was dropped into a dead socket.
///
/// The reopen itself needs a live service to exercise. What these pin is the
/// part that decides whether the sentence spoken *across* the gap survives —
/// which is the difference between a reconnect the user never notices and one
/// that costs them the words that prompted it.
struct ReconnectBufferTests {

    private func makeClient() -> TranslationClient {
        TranslationClient(config: .init(
            apiKey: "test", workspaceID: "test", targetLanguage: "en",
            sourceLanguage: "zh"
        ))
    }

    /// Sixteen-bit samples, so the byte budget means what the comment says.
    private func audio(bytes: Int) -> Data {
        Data(repeating: 0x01, count: bytes)
    }

    /// The fix in one test: audio handed over while the socket is down is
    /// kept, not discarded.
    @Test func audioSpokenDuringTheGapIsKept() {
        let client = makeClient()
        client.simulateDropForTesting()

        client.sendAudio(audio(bytes: 3_200))

        #expect(client.bufferedBytesForTesting == 3_200)
    }

    /// And replayed in order once the reopened session is configured.
    @Test func heldAudioIsReplayedInOrder() {
        let client = makeClient()
        client.simulateDropForTesting()

        let first = Data(repeating: 0x01, count: 320)
        let second = Data(repeating: 0x02, count: 320)
        client.sendAudio(first)
        client.sendAudio(second)

        #expect(client.drainBufferForTesting() == [first, second])
        // Draining hands the audio on rather than keeping a second copy.
        #expect(client.bufferedBytesForTesting == 0)
    }

    /// An outage longer than the buffer's budget must not grow without end —
    /// the audio is arriving from a live capture that never pauses.
    @Test func aLongOutageIsBoundedToTheMostRecentAudio() {
        let client = makeClient()
        client.simulateDropForTesting()

        let budget = TranslationClient.reconnectBufferBytesForTesting
        let chunk = 3_200
        // Twice the budget's worth, in order.
        for _ in 0..<((budget / chunk) * 2) {
            client.sendAudio(audio(bytes: chunk))
        }

        #expect(client.bufferedBytesForTesting <= budget)
        #expect(client.bufferedBytesForTesting > 0)
    }

    /// Trimming drops the oldest audio, not the newest: what is worth keeping
    /// across a gap is the words just spoken, and stale speech arrives too
    /// late to be worth translating anyway.
    @Test func trimmingDropsTheOldestAudioFirst() {
        let client = makeClient()
        client.simulateDropForTesting()

        let budget = TranslationClient.reconnectBufferBytesForTesting
        let chunk = 3_200
        let newest = Data(repeating: 0xFF, count: chunk)
        for _ in 0..<((budget / chunk) + 4) {
            client.sendAudio(audio(bytes: chunk))
        }
        client.sendAudio(newest)

        #expect(client.bufferedChunksForTesting.last == newest)
    }

    /// A retired client is one the caller finished with. Capture can outlive
    /// the session by a buffer or two, and holding that audio would mean a
    /// stopped session quietly retaining the last second of a call.
    @Test func aRetiredClientHoldsNothing() {
        let client = makeClient()
        client.simulateDropForTesting()
        client.retireForTesting()

        client.sendAudio(audio(bytes: 3_200))

        #expect(client.bufferedBytesForTesting == 0)
    }

    /// `close()` is the caller saying they are done, so it must leave nothing
    /// behind and nothing pending a reopen.
    @Test func closingClearsWhatWasHeld() {
        let client = makeClient()
        client.simulateDropForTesting()
        client.sendAudio(audio(bytes: 3_200))
        #expect(client.bufferedBytesForTesting == 3_200)

        client.close()

        #expect(client.bufferedBytesForTesting == 0)
        // And a late buffer from a capture still winding down is ignored.
        client.sendAudio(audio(bytes: 3_200))
        #expect(client.bufferedBytesForTesting == 0)
    }
}
