import Foundation

/// One direction of live translation, whichever service is behind it.
///
/// The audio path, the subtitle board and the diagnostics replay only ever
/// need these few calls, and they all speak `TranslationClient.Event` — the
/// event vocabulary the board was built on. A provider that maps its own
/// protocol onto those events can therefore stand in for Model Studio without
/// the rest of the app knowing which one is running.
nonisolated protocol LiveTranslationSession: AnyObject, Sendable {
    var onEvent: (@Sendable (TranslationClient.Event) -> Void)? { get set }

    /// True once the session has failed or been closed; stop sending audio.
    var isFailed: Bool { get }

    func connect()

    /// 16 kHz mono Int16 PCM, in any chunk size.
    func sendAudio(_ pcm: Data)

    /// Waits for the service to accept the session configuration. False if
    /// the connection failed first.
    func waitUntilReady(timeout: TimeInterval) async -> Bool

    /// Ends the stream so the last utterance is still delivered, then closes.
    func finish() async

    /// Tears down at once; nothing reopens a closed session.
    func close()
}

nonisolated extension LiveTranslationSession {
    func waitUntilReady() async -> Bool { await waitUntilReady(timeout: 15) }
}

nonisolated extension TranslationClient: LiveTranslationSession {}

/// Which service translates. Stored by raw value, so the spellings are fixed.
nonisolated enum TranslationProvider: String, CaseIterable, Identifiable, Sendable {
    /// Alibaba Model Studio, qwen3.8 LiveTranslate.
    case qwen
    /// Volcengine Doubao simultaneous interpretation 2.0.
    case doubao

    var id: String { rawValue }

    /// Whether the provider can both recognise and translate into `code`.
    /// A pair outside this set is refused before connecting, rather than left
    /// for the service to reject mid-handshake. Model Studio covers the whole
    /// menu in `Language.common`.
    func supports(_ code: String) -> Bool {
        switch self {
        case .qwen: true
        case .doubao: DoubaoTranslationClient.supportedLanguages.contains(code)
        }
    }
}
