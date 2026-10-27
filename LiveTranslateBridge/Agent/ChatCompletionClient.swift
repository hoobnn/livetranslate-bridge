import Foundation

/// The smallest client for an OpenAI-compatible `chat/completions` endpoint:
/// Volcengine Ark (Doubao's chat models) by default, but any provider that
/// speaks the same schema works by changing the base URL.
nonisolated enum ChatCompletionClient {
    struct Message: Sendable, Equatable {
        enum Role: String, Sendable { case system, user, assistant }
        var role: Role
        var content: String
    }

    struct ServiceError: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    static func requestBody(model: String, messages: [Message]) -> [String: Any] {
        [
            "model": model,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            // A phone call wants the same answer twice, not a creative one.
            "temperature": 0.4,
            "max_tokens": 400,
        ]
    }

    static func parseReply(_ data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError(message: String(decoding: data.prefix(400), as: UTF8.self))
        }
        if let error = object["error"] as? [String: Any] {
            throw ServiceError(message: error["message"] as? String ?? "chat request failed")
        }
        guard let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServiceError(message: "chat reply had no content")
        }
        return content
    }

    static func complete(
        _ messages: [Message], credentials: CredentialStore.AgentCredentials,
        session: URLSession = .shared
    ) async throws -> String {
        guard let base = URL(string: credentials.baseURL) else {
            throw ServiceError(message: "invalid base URL")
        }
        var request = URLRequest(url: base.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: requestBody(model: credentials.model, messages: messages)
        )
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ServiceError(
                message: "HTTP \(http.statusCode): \(String(decoding: data.prefix(400), as: UTF8.self))"
            )
        }
        return try parseReply(data)
    }
}
