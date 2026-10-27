import Foundation

/// The wire format of Doubao's simultaneous interpretation 2.0 service
/// (豆包同声传译 2.0, the Seed LiveInterpret model behind
/// `wss://openspeech.bytedance.com/api/v4/ast/v2/translate`).
///
/// Every frame in both directions is one binary WebSocket message holding a
/// single protobuf message: `TranslateRequest` going up, `TranslateResponse`
/// coming down. Only the handful of fields this app sends or reads are
/// modelled, and they are encoded by hand — the schema is small and stable,
/// and pulling in SwiftProtobuf for eight fields would add a dependency, a
/// code generator and a build step to an app that otherwise has none.
///
/// Field numbers follow the service's published `.proto` package.
nonisolated enum DoubaoProtocol {
    /// `event` on both messages.
    enum Event: Int32, Sendable {
        // Client → server.
        case startSession = 100
        case finishSession = 102
        case taskRequest = 200
        case updateConfig = 201

        // Server → client.
        case sessionStarted = 150
        case sessionCanceled = 151
        case sessionFinished = 152
        case sessionFailed = 153
        case usageResponse = 154
        case audioMuted = 250
        case ttsSentenceStart = 350
        case ttsSentenceEnd = 351
        case ttsResponse = 352
        case sourceSubtitleStart = 650
        case sourceSubtitleResponse = 651
        case sourceSubtitleEnd = 652
        case translationSubtitleStart = 653
        case translationSubtitleResponse = 654
        case translationSubtitleEnd = 655
    }

    /// `status_code` of a frame that carries no error.
    static let statusSuccess: Int32 = 20_000_000

    /// "s2t" returns subtitles only; "s2s" also returns synthesised speech.
    enum Mode: String, Sendable {
        case speechToText = "s2t"
        case speechToSpeech = "s2s"
    }

    struct AudioFormat: Sendable, Equatable {
        var format: String
        var codec: String?
        var rate: Int32
        var bits: Int32
        var channel: Int32

        /// What `Resampler` produces: 16 kHz mono signed 16-bit.
        static let source = AudioFormat(
            format: "wav", codec: "raw", rate: 16_000, bits: 16, channel: 1
        )

        /// The service's 24 kHz PCM is Float32 (16 kHz alone is Int16).
        /// `DoubaoTranslationClient` converts it to the player's Int16 PCM.
        static let target = AudioFormat(
            format: "pcm", codec: nil, rate: 24_000, bits: 32, channel: 1
        )
    }

    struct StartSession: Sendable, Equatable {
        var sessionID: String
        var userID: String
        var mode: Mode
        var sourceLanguage: String
        var targetLanguage: String
        /// Empty lets the service clone the speaker's own voice.
        var speakerID: String = ""
        var isCustomSpeaker = false
        /// Which synthesis resource `speakerID` belongs to. Empty with no
        /// speaker, where the service clones.
        var ttsResourceID = ""
        /// Source term → preferred translation.
        var glossary: [String: String] = [:]
    }

    // MARK: - requests

    static func startSession(_ start: StartSession) -> Data {
        var request = Writer()
        request.message(1, requestMeta(start.sessionID))
        request.int32(2, Event.startSession.rawValue)
        var user = Writer()
        user.string(1, start.userID)
        user.string(3, "macOS")
        user.string(4, "livetranslate-bridge")
        request.message(3, user.data)
        request.message(4, audio(AudioFormat.source))
        if start.mode == .speechToSpeech {
            request.message(5, audio(AudioFormat.target))
        }
        var params = Writer()
        params.string(1, start.mode.rawValue)
        params.string(2, start.sourceLanguage)
        params.string(3, start.targetLanguage)
        params.string(4, start.speakerID)
        // The current official ast_service.proto reserves 5 for speech_rate
        // and 6 for enable_source_language_detect.
        if start.isCustomSpeaker { params.bool(7, true) }
        params.string(8, start.ttsResourceID)
        if !start.glossary.isEmpty {
            var corpus = Writer()
            // Sorted so the same glossary always encodes to the same bytes,
            // which is what lets a test pin the frame.
            for (term, translation) in start.glossary.sorted(by: { $0.key < $1.key }) {
                var entry = Writer()
                entry.string(1, term)
                entry.string(2, translation)
                corpus.message(10, entry.data)
            }
            params.message(100, corpus.data)
        }
        request.message(6, params.data)
        // The service denoises unless told otherwise; the capture path
        // already hands it clean call audio, and a second pass smears the
        // consonants the recogniser relies on.
        request.bool(7, false)
        return request.data
    }

    static func audioChunk(sessionID: String, pcm: Data) -> Data {
        var audio = Writer()
        audio.bytes(14, pcm)
        var request = Writer()
        request.message(1, requestMeta(sessionID))
        request.int32(2, Event.taskRequest.rawValue)
        request.message(4, audio.data)
        return request.data
    }

    static func finishSession(sessionID: String) -> Data {
        var request = Writer()
        request.message(1, requestMeta(sessionID))
        request.int32(2, Event.finishSession.rawValue)
        return request.data
    }

    private static func requestMeta(_ sessionID: String) -> Data {
        var meta = Writer()
        meta.string(6, sessionID)
        return meta.data
    }

    private static func audio(_ format: AudioFormat) -> Data {
        var audio = Writer()
        audio.string(4, format.format)
        if let codec = format.codec { audio.string(5, codec) }
        audio.int32(7, format.rate)
        audio.int32(8, format.bits)
        audio.int32(9, format.channel)
        return audio.data
    }

    // MARK: - responses

    struct Response: Sendable, Equatable {
        var event: Int32 = 0
        var sessionID = ""
        var sequence: Int32 = 0
        var statusCode: Int32 = 0
        var message = ""
        /// Synthesised audio, on `ttsResponse`.
        var data = Data()
        var text = ""
        var startTime: Int32 = 0
        var endTime: Int32 = 0
        var speakerChanged = false
        var mutedDuration: Int32 = 0
        var detectedLanguage = ""

        var kind: Event? { Event(rawValue: event) }

        /// A frame whose status says the request failed. Zero means the
        /// service left the status out, which it does on routine frames.
        var isError: Bool { statusCode != 0 && statusCode != statusSuccess }
    }

    struct DecodingError: Error, Equatable {
        let reason: String
    }

    static func decodeResponse(_ data: Data) throws -> Response {
        var response = Response()
        var reader = Reader(data)
        while let entry = try reader.next() {
            let (field, value) = entry
            switch (field, value) {
            case (1, .bytes(let meta)):
                var metaReader = Reader(meta)
                while let entry = try metaReader.next() {
                    let (metaField, metaValue) = entry
                    switch (metaField, metaValue) {
                    case (1, .bytes(let id)): response.sessionID = String(decoding: id, as: UTF8.self)
                    case (2, .varint(let v)): response.sequence = Int32(truncatingIfNeeded: v)
                    case (3, .varint(let v)): response.statusCode = Int32(truncatingIfNeeded: v)
                    case (4, .bytes(let m)): response.message = String(decoding: m, as: UTF8.self)
                    default: break
                    }
                }
            case (2, .varint(let v)): response.event = Int32(truncatingIfNeeded: v)
            case (3, .bytes(let audio)): response.data = audio
            case (4, .bytes(let text)): response.text = String(decoding: text, as: UTF8.self)
            case (5, .varint(let v)): response.startTime = Int32(truncatingIfNeeded: v)
            case (6, .varint(let v)): response.endTime = Int32(truncatingIfNeeded: v)
            case (7, .varint(let v)): response.speakerChanged = v != 0
            case (8, .varint(let v)): response.mutedDuration = Int32(truncatingIfNeeded: v)
            case (9, .bytes(let language)):
                response.detectedLanguage = String(decoding: language, as: UTF8.self)
            default: break
            }
        }
        return response
    }

    #if DEBUG
    /// The server side of `decodeResponse`, so tests can build frames the way
    /// the service sends them rather than as opaque byte literals.
    static func encodeResponseForTesting(_ response: Response) -> Data {
        var meta = Writer()
        meta.string(1, response.sessionID)
        if response.sequence != 0 { meta.int32(2, response.sequence) }
        if response.statusCode != 0 { meta.int32(3, response.statusCode) }
        meta.string(4, response.message)
        var frame = Writer()
        frame.message(1, meta.data)
        frame.int32(2, response.event)
        frame.bytes(3, response.data)
        frame.string(4, response.text)
        if response.startTime != 0 { frame.int32(5, response.startTime) }
        if response.endTime != 0 { frame.int32(6, response.endTime) }
        if response.speakerChanged { frame.bool(7, true) }
        if response.mutedDuration != 0 { frame.int32(8, response.mutedDuration) }
        frame.string(9, response.detectedLanguage)
        return frame.data
    }
    #endif

    // MARK: - protobuf primitives

    enum Value: Equatable {
        case varint(UInt64)
        case bytes(Data)
        case fixed32
        case fixed64
    }

    struct Writer {
        private(set) var data = Data()

        mutating func varint(_ value: UInt64) {
            var value = value
            while value >= 0x80 {
                data.append(UInt8(truncatingIfNeeded: value) | 0x80)
                value >>= 7
            }
            data.append(UInt8(value))
        }

        mutating func tag(_ field: Int, _ wire: UInt64) {
            varint(UInt64(field) << 3 | wire)
        }

        /// Negative values sign-extend to ten bytes, as protobuf's `int32`
        /// does; none of the fields sent here are ever negative.
        mutating func int32(_ field: Int, _ value: Int32) {
            tag(field, 0)
            varint(UInt64(bitPattern: Int64(value)))
        }

        mutating func bool(_ field: Int, _ value: Bool) {
            tag(field, 0)
            data.append(value ? 1 : 0)
        }

        /// Empty values are omitted, which is proto3's own default.
        mutating func bytes(_ field: Int, _ value: Data) {
            guard !value.isEmpty else { return }
            tag(field, 2)
            varint(UInt64(value.count))
            data.append(value)
        }

        mutating func string(_ field: Int, _ value: String) {
            bytes(field, Data(value.utf8))
        }

        mutating func message(_ field: Int, _ value: Data) {
            bytes(field, value)
        }
    }

    struct Reader {
        private let data: Data
        private var offset: Int

        init(_ data: Data) {
            // Rebased: a `Data` slice keeps its parent's indices.
            self.data = Data(data)
            offset = 0
        }

        private mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard offset < data.count else { throw DecodingError(reason: "truncated varint") }
                guard shift < 64 else { throw DecodingError(reason: "varint too long") }
                let byte = data[offset]
                offset += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { return value }
                shift += 7
            }
        }

        private mutating func skip(_ count: Int) throws {
            guard count >= 0, offset + count <= data.count else {
                throw DecodingError(reason: "field runs past the end of the frame")
            }
            offset += count
        }

        mutating func next() throws -> (Int, Value)? {
            guard offset < data.count else { return nil }
            let key = try varint()
            let field = Int(key >> 3)
            guard field > 0 else { throw DecodingError(reason: "invalid field number") }
            switch key & 0x7 {
            case 0:
                return (field, .varint(try varint()))
            case 1:
                try skip(8)
                return (field, .fixed64)
            case 2:
                let length = try varint()
                guard length <= UInt64(data.count - offset) else {
                    throw DecodingError(reason: "field runs past the end of the frame")
                }
                let start = offset
                try skip(Int(length))
                return (field, .bytes(data.subdata(in: start..<offset)))
            case 5:
                try skip(4)
                return (field, .fixed32)
            default:
                throw DecodingError(reason: "unsupported wire type \(key & 0x7)")
            }
        }
    }
}
