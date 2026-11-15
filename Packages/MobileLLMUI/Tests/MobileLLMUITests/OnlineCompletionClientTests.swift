// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI

/// `OnlineCompletionClient` over a canned `URLProtocol` (no network): dialect negotiation, caching, auth,
/// and the error contract the compaction and web-search callers depend on.
final class OnlineCompletionClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubProtocol.reset()
    }

    private func makeClient(dialects: OnlineDialectCache = OnlineDialectCache()) -> OnlineCompletionClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return OnlineCompletionClient(session: URLSession(configuration: config), dialects: dialects)
    }

    private func service(base: String = "https://gateway.example.com/v1", model: String? = "m") -> OnlineService {
        OnlineService(id: "svc", name: "Svc", baseURL: base, modelID: model)
    }

    private let messages = [OnlineCompletionClient.Message(role: "user", content: "hi")]

    func testResponsesDialectReturnsOutputText() async throws {
        StubProtocol.respond = { _ in (200, #"{"output_text":"hello"}"#) }
        let text = try await makeClient().complete(service: service(), apiKey: "k", messages: messages)
        XCTAssertEqual(text, "hello")
        XCTAssertEqual(StubProtocol.paths, ["/v1/responses"])
        XCTAssertEqual(StubProtocol.authorization, "Bearer k")
    }

    func testFallsBackToChatCompletionsOn404AndCachesDialect() async throws {
        StubProtocol.respond = { path in
            path.hasSuffix("/responses")
                ? (404, "{}")
                : (200, #"{"choices":[{"message":{"content":"legacy"}}]}"#)
        }
        let cache = OnlineDialectCache()
        let client = makeClient(dialects: cache)
        let first = try await client.complete(service: service(), apiKey: "", messages: messages)
        XCTAssertEqual(first, "legacy")
        XCTAssertEqual(StubProtocol.paths, ["/v1/responses", "/v1/chat/completions"])

        StubProtocol.paths.removeAll()
        _ = try await client.complete(service: service(), apiKey: "", messages: messages)
        XCTAssertEqual(StubProtocol.paths, ["/v1/chat/completions"], "negotiated dialect must be cached")
        XCTAssertNil(StubProtocol.authorization, "an empty key sends no Authorization header")
    }

    func testBadStatusIsReported() async {
        StubProtocol.respond = { _ in (401, "{}") }
        do {
            _ = try await makeClient().complete(service: service(), apiKey: "k", messages: messages)
            XCTFail("expected badStatus")
        } catch {
            XCTAssertEqual(error as? OnlineCompletionError, .badStatus(401))
        }
    }

    func testUnusableBodyIsReported() async {
        StubProtocol.respond = { _ in (200, #"{"unexpected":true}"#) }
        do {
            _ = try await makeClient().complete(service: service(), apiKey: "k", messages: messages)
            XCTFail("expected unusableResponse")
        } catch {
            XCTAssertEqual(error as? OnlineCompletionError, .unusableResponse)
        }
    }

    func testMissingModelOrBadBaseURLIsInvalidConfigurationWithoutNetwork() async {
        for svc in [service(model: nil), service(model: ""), service(base: "http://api.openai.com/v1")] {
            do {
                _ = try await makeClient().complete(service: svc, apiKey: "k", messages: messages)
                XCTFail("expected invalidConfiguration")
            } catch {
                XCTAssertEqual(error as? OnlineCompletionError, .invalidConfiguration)
            }
        }
        XCTAssertTrue(StubProtocol.paths.isEmpty, "invalid configuration must never reach the network")
    }
}

// MARK: - Stub

private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var respond: (String) -> (Int, String) = { _ in (500, "") }
    nonisolated(unsafe) static var paths: [String] = []
    nonisolated(unsafe) static var authorization: String?

    static func reset() {
        respond = { _ in (500, "") }
        paths = []
        authorization = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.paths.append(path)
        Self.authorization = request.value(forHTTPHeaderField: "Authorization")
        let (status, body) = Self.respond(path)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
