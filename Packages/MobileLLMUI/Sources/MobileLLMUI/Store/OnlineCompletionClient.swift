// SPDX-License-Identifier: MIT

import Foundation

/// Wire dialect of an OpenAI-compatible endpoint.
public enum OnlineWireDialect: Equatable, Sendable {
    case responses
    case chatCompletions
}

/// Failures the client itself decides on. Transport errors (`URLError`, cancellation) propagate unchanged
/// so callers can tell "the service is broken" from "the user stopped".
public enum OnlineCompletionError: Error, Equatable {
    /// Base URL invalid or no model id configured. Never guess a model name.
    case invalidConfiguration
    /// The service answered with a non-2xx status.
    case badStatus(Int)
    /// 2xx, but no usable text in the body.
    case unusableResponse
}

/// Negotiated wire dialect per normalized base URL, so a gateway that only implements /chat/completions
/// is not probed on every call. Mirrors the agent runtime's provider cache.
public final class OnlineDialectCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: OnlineWireDialect] = [:]

    public init() {}

    public subscript(key: String) -> OnlineWireDialect? {
        get { lock.withLock { storage[key] } }
        set { lock.withLock { storage[key] = newValue } }
    }
}

/// One-shot, non-streaming completion against an OpenAI-compatible service: `/responses` first, falling
/// back once to `/chat/completions` on 404/405. Deliberately light — it never touches the agent runtime's
/// authorization pipeline; callers that need approval (web search) run it inside their own boundary.
public struct OnlineCompletionClient: Sendable {
    public struct Message: Sendable, Equatable {
        public let role: String
        public let content: String
        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    private let session: URLSession
    private let dialects: OnlineDialectCache

    public init(session: URLSession = .shared, dialects: OnlineDialectCache = OnlineDialectCache()) {
        self.session = session
        self.dialects = dialects
    }

    /// Normalized base URL used as the dialect-cache key (the request itself keeps the user's casing).
    static func requestBase(for service: OnlineService) -> (raw: String, key: String)? {
        let rawBaseURL = service.baseURL.isEmpty ? OpenAIServiceConfiguration.defaultBaseURL : service.baseURL
        guard let base = URL(string: rawBaseURL), OpenAIServiceConfiguration.isValidBaseURL(base) else {
            return nil
        }
        let raw = base.absoluteString.hasSuffix("/")
            ? String(base.absoluteString.dropLast())
            : base.absoluteString
        return (raw, raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    public func complete(
        service: OnlineService,
        apiKey: String,
        messages: [Message],
        temperature: Double = 0.2,
        maxOutputTokens: Int = 512,
        timeout: TimeInterval = 30
    ) async throws -> String {
        guard let base = Self.requestBase(for: service),
              let model = service.modelID, !model.isEmpty
        else { throw OnlineCompletionError.invalidConfiguration }

        let payload = messages.map { ["role": $0.role, "content": $0.content] }

        func makeRequest(_ dialect: OnlineWireDialect) throws -> URLRequest {
            let suffix = dialect == .chatCompletions ? "/chat/completions" : "/responses"
            guard let url = URL(string: base.raw + suffix) else {
                throw OnlineCompletionError.invalidConfiguration
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            request.timeoutInterval = timeout
            let body: [String: Any] = dialect == .responses
                ? ["model": model, "input": payload, "temperature": temperature,
                   "max_output_tokens": maxOutputTokens]
                : ["model": model, "messages": payload, "temperature": temperature,
                   "max_tokens": maxOutputTokens]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request
        }

        var current = dialects[base.key] ?? .responses
        var lastStatus: Int?
        for attempt in 0..<2 {
            let (data, response) = try await session.data(for: try makeRequest(current))
            if let http = response as? HTTPURLResponse {
                lastStatus = http.statusCode
                if (200...299).contains(http.statusCode) {
                    if let text = Self.extractText(data, dialect: current) {
                        dialects[base.key] = current
                        return text
                    }
                    throw OnlineCompletionError.unusableResponse
                }
                if (http.statusCode == 404 || http.statusCode == 405),
                   current == .responses, attempt == 0 {
                    // One-dialect gateway: remember and retry once via the legacy endpoint.
                    dialects[base.key] = .chatCompletions
                    current = .chatCompletions
                    continue
                }
            }
            break
        }
        if let lastStatus { throw OnlineCompletionError.badStatus(lastStatus) }
        throw OnlineCompletionError.unusableResponse
    }

    /// Performs a cloud-backed web search query using the configured online service.
    public func webSearch(
        service: OnlineService,
        apiKey: String,
        query: String,
        timeout: TimeInterval = 30
    ) async throws -> String {
        let systemPrompt = """
            You are a real-time web search backend. Search the web for the user's query and return \
            concise factual findings with source URLs and dates when available. Do not speculate or \
            fabricate sources; if no reliable results are found, state that clearly.
            """
        let messages = [
            Message(role: "system", content: systemPrompt),
            Message(role: "user", content: query),
        ]
        return try await complete(
            service: service,
            apiKey: apiKey,
            messages: messages,
            temperature: 0.2,
            maxOutputTokens: 1024,
            timeout: timeout
        )
    }

    static func extractText(_ data: Data, dialect: OnlineWireDialect) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if dialect == .responses {
            // Responses API: simplified top-level "output_text", or structured output[].content[].text.
            if let text = json["output_text"] as? String { return text }
            guard let output = json["output"] as? [[String: Any]],
                  let message = output.first(where: { ($0["type"] as? String) == "message" }),
                  let content = message["content"] as? [[String: Any]] else { return nil }
            return content.compactMap { $0["text"] as? String }.joined()
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        return content
    }
}
