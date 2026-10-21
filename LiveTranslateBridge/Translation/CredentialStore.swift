import Foundation
import Security

/// Stores the Model Studio and Doubao credentials in the login keychain.
///
/// The CLI read these from `.env`, which a bundled app cannot do: it has no
/// project directory to walk up from, and shipping a file with the key beside
/// the binary defeats the point. The keychain also survives reinstalls and
/// keeps the key out of any backup of the app's container.
///
/// The environment is still consulted first so a debug run from Xcode can
/// override the stored value with a scheme variable.
nonisolated struct CredentialStore {
    struct Credentials: Sendable, Equatable {
        var apiKey: String
        var workspaceID: String

        var isComplete: Bool { !apiKey.isEmpty && !workspaceID.isEmpty }
    }

    /// One keychain item holds both fields; they are useless apart.
    ///
    /// Spelled with the original bundle identifier rather than the current
    /// product name: renaming it would strand the credentials already stored
    /// under the old service, forcing everyone to re-enter their key.
    private static let service = "com.ikuyu.livetranslate-bridge.dashscope"
    private static let account = "default"

    static func load() -> Credentials {
        if let fromEnvironment = environmentCredentials() { return fromEnvironment }

        guard let data = read(service: service),
              let decoded = try? JSONDecoder().decode(Stored.self, from: data)
        else {
            return Credentials(apiKey: "", workspaceID: "")
        }
        return Credentials(apiKey: decoded.apiKey, workspaceID: decoded.workspaceID)
    }

    @discardableResult
    static func save(_ credentials: Credentials) -> Bool {
        guard let data = try? JSONEncoder().encode(
            Stored(apiKey: credentials.apiKey, workspaceID: credentials.workspaceID)
        ) else { return false }
        return write(data, service: service)
    }

    @discardableResult
    static func clear() -> Bool { delete(service: service) }

    /// Whichever provider's credentials a session needs.
    enum ForProvider: Sendable, Equatable {
        case qwen(Credentials)
        case doubao(DoubaoCredentials)

        var isComplete: Bool {
            switch self {
            case .qwen(let credentials): credentials.isComplete
            case .doubao(let credentials): credentials.isComplete
            }
        }
    }

    static func load(for provider: TranslationProvider) -> ForProvider {
        switch provider {
        case .qwen: .qwen(load())
        case .doubao: .doubao(loadDoubao())
        }
    }

    // MARK: - Doubao

    /// Volcengine speech console credentials, kept apart from Model Studio's
    /// so switching providers never costs the other provider's key.
    struct DoubaoCredentials: Sendable, Equatable, Codable {
        /// Empty when the console issued a single API key instead.
        var appID: String
        /// The Access Token that goes with `appID`, or the API key alone.
        var accessToken: String
        /// A stock speaker for when voice cloning is off. Empty lets the
        /// service decide.
        var speakerID: String = ""
        /// A voice trained from the user's own sample (`S_…`, from the
        /// console's voice cloning). When set, both the AI agent and the
        /// user's own translated speech use it, so taking over a call never
        /// changes how "you" sound.
        var cloneSpeakerID: String = ""

        var isComplete: Bool { !accessToken.isEmpty }

        init(appID: String, accessToken: String, speakerID: String = "",
             cloneSpeakerID: String = "") {
            self.appID = appID
            self.accessToken = accessToken
            self.speakerID = speakerID
            self.cloneSpeakerID = cloneSpeakerID
        }

        /// Tolerates items saved before a field existed.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            appID = try container.decodeIfPresent(String.self, forKey: .appID) ?? ""
            accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken) ?? ""
            speakerID = try container.decodeIfPresent(String.self, forKey: .speakerID) ?? ""
            cloneSpeakerID = try container.decodeIfPresent(String.self, forKey: .cloneSpeakerID) ?? ""
        }
    }

    private static let doubaoService = "com.ikuyu.livetranslate-bridge.doubao"

    static func loadDoubao() -> DoubaoCredentials {
        let environment = ProcessInfo.processInfo.environment
        if let token = environment["DOUBAO_ACCESS_TOKEN"] ?? environment["DOUBAO_API_KEY"],
           !token.isEmpty {
            return DoubaoCredentials(appID: environment["DOUBAO_APP_ID"] ?? "",
                                     accessToken: token,
                                     speakerID: environment["DOUBAO_SPEAKER_ID"] ?? "",
                                     cloneSpeakerID: environment["DOUBAO_CLONE_SPEAKER_ID"] ?? "")
        }
        guard let data = read(service: doubaoService),
              let decoded = try? JSONDecoder().decode(DoubaoCredentials.self, from: data)
        else { return DoubaoCredentials(appID: "", accessToken: "") }
        return decoded
    }

    @discardableResult
    static func saveDoubao(_ credentials: DoubaoCredentials) -> Bool {
        guard let data = try? JSONEncoder().encode(credentials) else { return false }
        return write(data, service: doubaoService)
    }

    @discardableResult
    static func clearDoubao() -> Bool { delete(service: doubaoService) }

    // MARK: - AI agent

    /// An OpenAI-compatible chat completions endpoint for the call agent.
    /// Defaults to Volcengine Ark, where Doubao's chat models live.
    struct AgentCredentials: Sendable, Equatable, Codable {
        static let defaultBaseURL = "https://ark.cn-beijing.volces.com/api/v3"

        var baseURL: String = AgentCredentials.defaultBaseURL
        var apiKey: String = ""
        /// A model name, or an Ark endpoint ID (`ep-…`).
        var model: String = ""

        var isComplete: Bool { !apiKey.isEmpty && !model.isEmpty && URL(string: baseURL) != nil }
    }

    private static let agentService = "com.ikuyu.livetranslate-bridge.agent"

    static func loadAgent() -> AgentCredentials {
        let environment = ProcessInfo.processInfo.environment
        if let key = environment["AGENT_API_KEY"], !key.isEmpty {
            return AgentCredentials(
                baseURL: environment["AGENT_BASE_URL"] ?? AgentCredentials.defaultBaseURL,
                apiKey: key, model: environment["AGENT_MODEL"] ?? ""
            )
        }
        guard let data = read(service: agentService),
              let decoded = try? JSONDecoder().decode(AgentCredentials.self, from: data)
        else { return AgentCredentials() }
        return decoded
    }

    @discardableResult
    static func saveAgent(_ credentials: AgentCredentials) -> Bool {
        guard let data = try? JSONEncoder().encode(credentials) else { return false }
        return write(data, service: agentService)
    }

    @discardableResult
    static func clearAgent() -> Bool { delete(service: agentService) }

    // MARK: - keychain

    private static func read(service: String) -> Data? {
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
        else { return nil }
        return item as? Data
    }

    private static func write(_ data: Data, service: String) -> Bool {
        // Update in place when an item already exists; SecItemAdd would fail
        // with errSecDuplicateItem.
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(
            baseQuery(service: service) as CFDictionary, update as CFDictionary
        )
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }

        var insert = baseQuery(service: service)
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    private static func delete(service: String) -> Bool {
        let status = SecItemDelete(baseQuery(service: service) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func environmentCredentials() -> Credentials? {
        let environment = ProcessInfo.processInfo.environment
        guard let apiKey = environment["DASHSCOPE_API_KEY"], !apiKey.isEmpty,
              let workspaceID = environment["DASHSCOPE_WORKSPACE_ID"],
              !workspaceID.isEmpty else { return nil }
        return Credentials(apiKey: apiKey, workspaceID: workspaceID)
    }

    private struct Stored: Codable {
        let apiKey: String
        let workspaceID: String
    }
}
