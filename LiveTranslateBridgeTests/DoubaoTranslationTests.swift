//
//  DoubaoTranslationTests.swift
//  LiveTranslateBridgeTests
//

import Foundation
import Testing
@testable import LiveTranslateBridge

/// Reads a request frame back field by field, so the tests check what goes on
/// the wire rather than restating the encoder.
private func fields(_ data: Data) throws -> [Int: [DoubaoProtocol.Value]] {
    var reader = DoubaoProtocol.Reader(data)
    var out: [Int: [DoubaoProtocol.Value]] = [:]
    while let entry = try reader.next() { out[entry.0, default: []].append(entry.1) }
    return out
}

private func bytes(_ value: DoubaoProtocol.Value?) -> Data? {
    if case .bytes(let data) = value { return data }
    return nil
}

private func string(_ value: DoubaoProtocol.Value?) -> String? {
    bytes(value).map { String(decoding: $0, as: UTF8.self) }
}

private func varint(_ value: DoubaoProtocol.Value?) -> UInt64? {
    if case .varint(let v) = value { return v }
    return nil
}

struct DoubaoProtocolTests {
    @Test func startSessionCarriesModeLanguagesAndAudioFormats() throws {
        let frame = DoubaoProtocol.startSession(.init(
            sessionID: "s-1", userID: "u", mode: .speechToSpeech,
            sourceLanguage: "zh", targetLanguage: "en",
            glossary: ["豆包": "Doubao"]
        ))
        let top = try fields(frame)
        #expect(varint(top[2]?.first) == 100)
        #expect(string(try fields(bytes(top[1]?.first)!)[6]?.first) == "s-1")

        let source = try fields(bytes(top[4]?.first)!)
        #expect(string(source[4]?.first) == "wav")
        #expect(varint(source[7]?.first) == 16_000)
        #expect(varint(source[8]?.first) == 16)
        #expect(varint(source[9]?.first) == 1)

        // Speech-to-speech asks for exactly what the player plays.
        let target = try fields(bytes(top[5]?.first)!)
        #expect(string(target[4]?.first) == "pcm")
        #expect(varint(target[7]?.first) == 24_000)
        // The service's 24 kHz PCM is Float32, regardless of a 16-bit request.
        #expect(varint(target[8]?.first) == 32)

        let params = try fields(bytes(top[6]?.first)!)
        #expect(string(params[1]?.first) == "s2s")
        #expect(string(params[2]?.first) == "zh")
        #expect(string(params[3]?.first) == "en")
        // No speaker: the service clones the voice.
        #expect(params[4] == nil)
        #expect(params[8] == nil)
        let corpus = try fields(bytes(params[100]?.first)!)
        let entry = try fields(bytes(corpus[10]?.first)!)
        #expect(string(entry[1]?.first) == "豆包")
        #expect(string(entry[2]?.first) == "Doubao")
        #expect(varint(top[7]?.first) == 0)
    }

    @Test func textOnlySessionSendsNoTargetAudio() throws {
        let frame = DoubaoProtocol.startSession(.init(
            sessionID: "s", userID: "u", mode: .speechToText,
            sourceLanguage: "en", targetLanguage: "zh"
        ))
        let top = try fields(frame)
        #expect(top[5] == nil)
        #expect(string(try fields(bytes(top[6]?.first)!)[1]?.first) == "s2t")
    }

    @Test func customVoiceUsesTheCurrentProtobufFieldNumbers() throws {
        let frame = DoubaoProtocol.startSession(.init(
            sessionID: "s", userID: "u", mode: .speechToSpeech,
            sourceLanguage: "zh", targetLanguage: "en", speakerID: "S_test",
            isCustomSpeaker: true, ttsResourceID: "seed-icl-2.0"
        ))
        let top = try fields(frame)
        let params = try fields(bytes(top[6]?.first)!)
        #expect(varint(params[7]?.first) == 1)
        #expect(string(params[8]?.first) == "seed-icl-2.0")
        // These now mean speech_rate and enable_source_language_detect.
        #expect(params[5] == nil)
        #expect(params[6] == nil)
    }

    @Test func audioChunkIsATaskRequestWithBinaryData() throws {
        let pcm = Data((0..<640).map { UInt8($0 & 0xFF) })
        let top = try fields(DoubaoProtocol.audioChunk(sessionID: "s", pcm: pcm))
        #expect(varint(top[2]?.first) == 200)
        #expect(bytes(try fields(bytes(top[4]?.first)!)[14]?.first) == pcm)
    }

    @Test func responsesRoundTrip() throws {
        var response = DoubaoProtocol.Response()
        response.event = 654
        response.sessionID = "abc"
        response.sequence = 3
        response.statusCode = DoubaoProtocol.statusSuccess
        response.text = "hello"
        response.startTime = 120
        response.endTime = 980
        response.data = Data([1, 2, 3])
        let decoded = try DoubaoProtocol.decodeResponse(
            DoubaoProtocol.encodeResponseForTesting(response)
        )
        #expect(decoded == response)
        #expect(decoded.kind == .translationSubtitleResponse)
        #expect(!decoded.isError)
    }

    @Test func truncatedFrameIsAnErrorNotACrash() {
        #expect(throws: DoubaoProtocol.DecodingError.self) {
            try DoubaoProtocol.decodeResponse(Data([0x22, 0x10, 0x41]))
        }
    }

    @Test func mergeAcceptsSnapshotsAndIncrements() {
        #expect(DoubaoTranslationClient.merge("", "你好") == "你好")
        #expect(DoubaoTranslationClient.merge("你好", "你好世界") == "你好世界")
        #expect(DoubaoTranslationClient.merge("Hello", " world") == "Hello world")
        #expect(DoubaoTranslationClient.merge("Hello world", "world") == "Hello world")
        #expect(DoubaoTranslationClient.merge("Hello", "") == "Hello")
    }

    @Test func joinSpacesOnlyWordSeparatedLanguages() {
        #expect(DoubaoTranslationClient.join("A long", "sentence.", language: "en") == "A long sentence.")
        #expect(DoubaoTranslationClient.join("很长的", "一句话", language: "zh") == "很长的一句话")
        #expect(DoubaoTranslationClient.join("", "x", language: "en") == "x")
    }

    @Test func floatAudioClipsSafelyAndRejectsPartialSamples() {
        let floats: [Float] = [-2, -1, 0, 1, 2, .nan, .infinity]
        let input = floats.withUnsafeBytes { Data($0) }
        #expect(DoubaoTranslationClient.playerPCM(from: input) == Data([
            0, 0x80, 0, 0x80, 0, 0, 0xFF, 0x7F, 0xFF, 0x7F, 0, 0, 0, 0,
        ]))
        #expect(DoubaoTranslationClient.playerPCM(from: Data([0, 0, 0])) == nil)
    }
}

struct DoubaoConfigTests {
    private func config(
        target: String? = "en", wantsAudio: Bool = true,
        voice: TranslationClient.Config.Voice = .preset, preset: String = ""
    ) -> DoubaoTranslationClient.Config {
        .init(appID: "app", accessToken: "token", sourceLanguage: "zh",
              targetLanguage: target, wantsAudio: wantsAudio, voice: voice,
              presetSpeakerID: preset)
    }

    @Test func cloningLeavesTheSpeakerToTheService() {
        let start = config(voice: .cloneOnce).startSession(id: "s")
        #expect(start.mode == .speechToSpeech)
        #expect(start.speakerID.isEmpty)
        #expect(!start.isCustomSpeaker)
    }

    @Test func preClonedVoiceIsACustomSpeaker() {
        let start = config(voice: .cloned(id: "S_abc")).startSession(id: "s")
        #expect(start.speakerID == "S_abc")
        #expect(start.isCustomSpeaker)
        #expect(start.ttsResourceID == DoubaoTranslationClient.cloneResourceID)
    }

    @Test func presetUsesTheConfiguredSpeaker() {
        let start = config(voice: .preset, preset: "zh_female_vv").startSession(id: "s")
        #expect(start.speakerID == "zh_female_vv")
        #expect(start.ttsResourceID == DoubaoTranslationClient.presetResourceID)
    }

    @Test func cloningOffNeverFallsThroughToCloning() {
        // An empty speaker is the wire form of "clone the voice".
        let start = config(voice: .preset).startSession(id: "s")
        #expect(start.speakerID == DoubaoTranslationClient.defaultSpeakerID)
        #expect(!start.isCustomSpeaker)
    }

    @Test func pairsMustPivotOnChineseOrEnglish() {
        #expect(TranslationProvider.doubao.supportsPair("fr", "en"))
        #expect(TranslationProvider.doubao.supportsPair("zh", "ja"))
        #expect(!TranslationProvider.doubao.supportsPair("fr", "de"))
        #expect(TranslationProvider.qwen.supportsPair("fr", "de"))
    }

    @Test func textOnlyNeverSpeaks() {
        let start = config(wantsAudio: false, preset: "zh_female_vv").startSession(id: "s")
        #expect(start.mode == .speechToText)
        #expect(start.speakerID.isEmpty)
    }

    @Test func transcriptionStillNamesADifferentTarget() {
        let start = config(target: nil, wantsAudio: true).startSession(id: "s")
        #expect(start.mode == .speechToText)
        #expect(start.targetLanguage == "en")
        #expect(start.sourceLanguage == "zh")
    }

    @Test func koreanAndRussianAreRefusedUpFront() {
        #expect(!TranslationProvider.doubao.supports("ko"))
        #expect(!TranslationProvider.doubao.supports("ru"))
        #expect(TranslationProvider.doubao.supports("ja"))
        #expect(TranslationProvider.qwen.supports("ko"))
    }
}

/// Collects what the client reports, from whichever queue it reports on.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TranslationClient.Event] = []
    func append(_ event: TranslationClient.Event) { lock.lock(); events.append(event); lock.unlock() }
    var all: [TranslationClient.Event] { lock.lock(); defer { lock.unlock() }; return events }

    /// The identified text events, as "item:kind:text".
    var segments: [String] {
        all.compactMap { event in
            guard case .identified(let identity, let payload) = event,
                  let item = identity.itemID else { return nil }
            switch payload {
            case .transcript(let text): return "\(item):transcript:\(text)"
            case .transcriptComplete(let text): return "\(item):transcriptComplete:\(text)"
            case .translation(let text): return "\(item):translation:\(text)"
            case .translationComplete(let text): return "\(item):translationComplete:\(text)"
            case .responseFinished(let status): return "\(item):responseFinished:\(status)"
            default: return nil
            }
        }
    }
}

struct DoubaoClientEventTests {
    private func frame(
        _ event: Int32, _ text: String = "", start: Int32 = 0, end: Int32 = 0, audio: Data = Data()
    ) -> DoubaoProtocol.Response {
        var response = DoubaoProtocol.Response()
        response.event = event
        response.text = text
        response.startTime = start
        response.endTime = end
        response.data = audio
        return response
    }

    private func client(target: String? = "en") -> (DoubaoTranslationClient, EventLog) {
        let client = DoubaoTranslationClient(config: .init(
            appID: "", accessToken: "t", sourceLanguage: "zh",
            targetLanguage: target, wantsAudio: true, voice: .cloneOnce
        ))
        let log = EventLog()
        client.onEvent = { log.append($0) }
        return (client, log)
    }

    @Test func sourceAndTranslationOfOneSentenceShareACard() {
        let (client, log) = client()
        client.applyForTesting(frame(150))
        client.applyForTesting(frame(650))
        client.applyForTesting(frame(651, "你好"))
        client.applyForTesting(frame(651, "你好世界"))
        client.applyForTesting(frame(652, "你好世界。"))
        client.applyForTesting(frame(653))
        client.applyForTesting(frame(654, "Hello"))
        client.applyForTesting(frame(654, " world"))
        client.applyForTesting(frame(655))
        #expect(log.segments == [
            "seg-1:transcript:你好",
            "seg-1:transcript:你好世界",
            "seg-1:transcriptComplete:你好世界。",
            "seg-1:translation:Hello",
            "seg-1:translation:Hello world",
            "seg-1:translationComplete:Hello world",
        ])
        #expect(log.all.contains { if case .sessionReady = $0 { return true }; return false })
        client.close()
    }

    @Test func aTranslationSpanningTwoSentencesClosesTheSecondCard() {
        let (client, log) = client()
        client.applyForTesting(frame(150))
        client.applyForTesting(frame(650, start: 1_000)); client.applyForTesting(frame(652, "第一句"))
        client.applyForTesting(frame(650, start: 3_000)); client.applyForTesting(frame(652, "第二句"))
        client.applyForTesting(frame(650, start: 5_000)); client.applyForTesting(frame(652, "第三句"))
        // One translation for the first two, timed from the first.
        client.applyForTesting(frame(653, start: 1_000)); client.applyForTesting(frame(655, "One and two."))
        client.applyForTesting(frame(653, start: 5_000)); client.applyForTesting(frame(655, "Three."))
        #expect(log.segments.contains("seg-1:translationComplete:One and two."))
        #expect(log.segments.contains("seg-2:responseFinished:completed"))
        #expect(log.segments.contains("seg-3:translationComplete:Three."))
        client.close()
    }

    @Test func aSentenceTranslatedInTwoPartsKeepsBothOnItsCard() {
        let (client, log) = client()
        client.applyForTesting(frame(150))
        client.applyForTesting(frame(650, start: 1_000)); client.applyForTesting(frame(652, "很长的一句话"))
        client.applyForTesting(frame(653, start: 1_000)); client.applyForTesting(frame(655, "A long"))
        client.applyForTesting(frame(653, start: 1_800)); client.applyForTesting(frame(655, "sentence."))
        #expect(log.segments.last == "seg-1:translationComplete:A long sentence.")
        #expect(!log.segments.contains { $0.hasPrefix("seg-2") })
        client.close()
    }

    @Test(arguments: [Int32(0), Int32(4_000)])
    func aTimedTranslationImmediatelyClosesEveryCoveredSourceCard(_ sourceEnd: Int32) {
        let (client, log) = client()
        client.applyForTesting(frame(150))
        client.applyForTesting(frame(650, start: 1_000))
        client.applyForTesting(frame(652, "第一句", end: 2_000))
        client.applyForTesting(frame(650, start: 3_000))
        client.applyForTesting(frame(652, "第二句", end: sourceEnd))
        client.applyForTesting(frame(650, start: 5_000))
        client.applyForTesting(frame(652, "第三句", end: 6_000))
        client.applyForTesting(frame(653, start: 1_000))
        client.applyForTesting(frame(655, "One and two.", start: 1_000, end: 4_000))
        #expect(log.segments.suffix(2) == [
            "seg-1:translationComplete:One and two.",
            "seg-2:responseFinished:completed",
        ])
        #expect(!log.segments.contains("seg-3:responseFinished:completed"))
        client.close()
    }

    @Test func translationPartsLeaveTheFollowingSourceCardOpen() {
        let (client, log) = client()
        client.applyForTesting(frame(150))
        client.applyForTesting(frame(650, start: 1_000))
        client.applyForTesting(frame(652, "很长的一句话", end: 2_800))
        client.applyForTesting(frame(650, start: 3_000))
        client.applyForTesting(frame(652, "下一句", end: 4_000))
        client.applyForTesting(frame(653, start: 1_000))
        client.applyForTesting(frame(655, "A long", start: 1_000, end: 1_800))
        client.applyForTesting(frame(653, start: 1_800))
        client.applyForTesting(frame(655, "sentence.", start: 1_800, end: 2_800))
        #expect(log.segments.last == "seg-1:translationComplete:A long sentence.")
        #expect(!log.segments.contains("seg-2:responseFinished:completed"))
        client.close()
    }

    @Test func aTranslationDoesNotCloseAnUncoveredOrPartiallyCoveredSource() {
        let ends: [Int32] = [3_000, 4_000]
        for end in ends {
            let (client, log) = client()
            client.applyForTesting(frame(150))
            client.applyForTesting(frame(650, start: 1_000))
            client.applyForTesting(frame(652, "第一句", end: 2_000))
            client.applyForTesting(frame(650, start: 3_000))
            client.applyForTesting(frame(652, "第二句", end: 5_000))
            client.applyForTesting(frame(653, start: 1_000))
            client.applyForTesting(frame(655, "First.", start: 1_000, end: end))
            #expect(!log.segments.contains("seg-2:responseFinished:completed"))
            client.close()
        }
    }

    @Test func missingOrInvalidTranslationTimingDoesNotGuessLaterCoverage() {
        let timings: [(Int32, Int32)] = [(0, 4_000), (1_000, 0), (1_000, 500)]
        for (start, end) in timings {
            let (client, log) = client()
            client.applyForTesting(frame(150))
            client.applyForTesting(frame(650, start: 1_000)); client.applyForTesting(frame(652, "第一句"))
            client.applyForTesting(frame(650, start: 3_000)); client.applyForTesting(frame(652, "第二句"))
            client.applyForTesting(frame(653, start: start))
            client.applyForTesting(frame(655, "First.", start: start, end: end))
            #expect(!log.segments.contains("seg-2:responseFinished:completed"))
            client.close()
        }
    }

    @Test func sessionEndClosesSourcesWithNoSeparateTranslationExactlyOnce() {
        let (client, log) = client()
        client.applyForTesting(frame(150))
        client.applyForTesting(frame(650)); client.applyForTesting(frame(652, "嗯"))
        client.applyForTesting(frame(650)); client.applyForTesting(frame(652, "好的"))
        client.applyForTesting(frame(653)); client.applyForTesting(frame(655, "Mm."))
        client.applyForTesting(frame(650)); client.applyForTesting(frame(651, "还没分句"))
        // Retire the transport before injecting its final response: this test
        // exercises segment finalization without scheduling a real reconnect.
        client.close()
        client.applyForTesting(frame(152))
        client.applyForTesting(frame(152))
        #expect(log.segments.filter { $0 == "seg-2:responseFinished:completed" }.count == 1)
        #expect(log.segments.filter { $0 == "seg-3:responseFinished:completed" }.count == 1)
        #expect(log.segments.contains("seg-3:transcriptComplete:还没分句"))
        #expect(!log.segments.contains("seg-1:responseFinished:completed"))
    }

    @Test func untimedTranslationsPairInOrder() {
        let (client, log) = client()
        client.applyForTesting(frame(150))
        client.applyForTesting(frame(650)); client.applyForTesting(frame(652, "嗯"))
        client.applyForTesting(frame(650)); client.applyForTesting(frame(652, "好的"))
        client.applyForTesting(frame(653)); client.applyForTesting(frame(655, "Mm."))
        client.applyForTesting(frame(653)); client.applyForTesting(frame(655, "Okay."))
        #expect(log.segments.contains("seg-1:translationComplete:Mm."))
        #expect(log.segments.contains("seg-2:translationComplete:Okay."))
        client.close()
    }

    @Test func transcriptionDropsTheTranslation() {
        let (client, log) = client(target: nil)
        client.applyForTesting(frame(150))
        client.applyForTesting(frame(650)); client.applyForTesting(frame(652, "原文"))
        client.applyForTesting(frame(653)); client.applyForTesting(frame(655, "Source"))
        #expect(log.segments == ["seg-1:transcriptComplete:原文"])
        client.close()
    }

    @Test func synthesisedSpeechGoesStraightToPlayback() {
        let (client, log) = client()
        client.applyForTesting(frame(150))
        // Real same-translation API payloads are 24 kHz Float32 LE. Both
        // ordinary audio frames and sentence-end frames can contain samples.
        client.applyForTesting(frame(352, audio: Data([0, 0, 0, 0xBF, 0, 0, 0, 0])))
        client.applyForTesting(frame(351, audio: Data([0, 0, 0, 0x3F])))
        let audio = log.all.compactMap { event -> Data? in
            if case .audio(let data) = event { return data }
            return nil
        }
        // The player takes signed Int16 LE: -0.5, 0, +0.5.
        #expect(audio == [Data([0, 0xC0, 0, 0]), Data([0, 0x40])])
        #expect(log.all.contains { if case .audioComplete = $0 { return true }; return false })
        client.close()
    }

    @Test func busyAndTimeoutAnswersAreRetriedNotFatal() {
        #expect(DoubaoTranslationClient.isTransient("55000031: server busy"))
        #expect(DoubaoTranslationClient.isTransient("45000081: packet timeout"))
        #expect(!DoubaoTranslationClient.isTransient("45000001: invalid access key"))
    }

    @Test func anErrorBeforeTheFirstSessionFailsVisibly() {
        let (client, log) = client()
        var error = frame(153)
        error.statusCode = 45_000_001
        error.message = "invalid access key"
        client.applyForTesting(error)
        #expect(log.all.contains { if case .failed = $0 { return true }; return false })
        client.close()
    }

    @Test func aClosedSessionIsNeverReady() async {
        let (client, _) = client()
        client.markStartedForTesting()
        client.close()
        #expect(await client.waitUntilReady(timeout: 0.1) == false)
    }

}
