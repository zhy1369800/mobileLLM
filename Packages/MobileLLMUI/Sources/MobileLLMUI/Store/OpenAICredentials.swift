// SPDX-License-Identifier: MIT

import Foundation
import AppRuntime

/// Where the OpenAI Responses API key lives. The app stores it in the device Keychain (this-device-only,
/// off-backup, never in UserDefaults or the repo); tests and the debug launcher can seed it through a
/// launch-environment variable, which is never committed.
public protocol OpenAICredentialStoring: Sendable {
    /// Stores one service's key. `serviceID` is the OnlineService identity (also the Keychain account).
    func saveAPIKey(_ key: String, serviceID: String) throws
    func loadAPIKey(serviceID: String) throws -> String?
    func deleteAPIKey(serviceID: String) throws
    func deleteAllAPIKeys(serviceIDs: [String]) throws
}

/// Convenience for the legacy single-service surface (the Mac-local config / test env seeding and the
/// default service). Defaults to `OnlineService.defaultID`.
public extension OpenAICredentialStoring {
    func deleteAllAPIKeys(serviceIDs: [String]) throws {
        for id in Set(serviceIDs + [OnlineService.defaultID]) { try deleteAPIKey(serviceID: id) }
    }
    func saveAPIKey(_ key: String) throws {
        try saveAPIKey(key, serviceID: OnlineService.defaultID)
    }

    func loadAPIKey() throws -> String? {
        try loadAPIKey(serviceID: OnlineService.defaultID)
    }

    func deleteAPIKey() throws {
        try deleteAPIKey(serviceID: OnlineService.defaultID)
    }
}

/// Keychain-backed store, scoped to its own service so it never collides with MCP bearer tokens.
public struct KeychainOpenAICredentialStore: OpenAICredentialStoring, Sendable {
    public static func defaultService(
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "mobileLLM"
    ) -> String {
        "\(bundleIdentifier).openai"
    }

    private let box: KeychainBox

    public init(service: String = KeychainOpenAICredentialStore.defaultService()) {
        box = KeychainBox(service: service)
    }

    public func saveAPIKey(_ key: String, serviceID: String) throws {
        try box.save(key, account: serviceID)
    }

    public func loadAPIKey(serviceID: String) throws -> String? {
        try box.readString(account: serviceID)
    }

    public func deleteAPIKey(serviceID: String) throws {
        try box.delete(account: serviceID)
    }

    public func deleteAllAPIKeys(serviceIDs: [String]) throws { try box.deleteAll() }
}

/// In-memory store for unit tests, previews, and any environment that must never touch the device
/// Keychain.
public final class EphemeralOpenAICredentialStore: OpenAICredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String] = [:]

    public init() {}

    public func saveAPIKey(_ key: String, serviceID: String) throws {
        lock.withLock { keys[serviceID] = key }
    }

    public func loadAPIKey(serviceID: String) throws -> String? {
        lock.withLock { keys[serviceID] }
    }

    public func deleteAPIKey(serviceID: String) throws {
        lock.withLock { keys[serviceID] = nil }
    }

    public func deleteAllAPIKeys(serviceIDs: [String]) throws { lock.withLock { keys.removeAll() } }
}

/// Debug-only launch-environment seeding: when the test runner injects
/// `MOBILELLM_OPENAI_API_KEY`, the app stores it once so device UI tests never need the key typed by
/// hand and the repository never contains it. Release builds ignore the environment entirely.
public enum OpenAIKeyEnvironment {
    public static let variableName = "MOBILELLM_OPENAI_API_KEY"
    public static let baseURLVariableName = "MOBILELLM_OPENAI_BASE_URL"
    public static let modelVariableName = "MOBILELLM_OPENAI_MODEL"

    public static func seedIfPresent(
        store: any OpenAICredentialStoring,
        environment: [String: String]
    ) {
        #if DEBUG
        guard let key = environment[variableName], !key.isEmpty else { return }
        try? store.saveAPIKey(key)
        #endif
    }
}

/// Non-secret service configuration for the Responses API. The base URL may point at a gateway,
/// proxy, or self-hosted endpoint; it is persisted in Settings (unlike the key, which stays in the
/// Keychain). Https is preferred, but http is accepted for local or private-network endpoints.
public enum OpenAIServiceConfiguration {
    public static let defaultBaseURL = "https://api.openai.com/v1"

    /// Returns true if the host is a local hostname or in a private / loopback IP range.
    public static func isLocalOrPrivateHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.isEmpty { return false }
        if host == "localhost"
            || host.hasSuffix(".localhost")
            || host == "local"
            || host.hasSuffix(".local")
            || host == "home.arpa"
            || host.hasSuffix(".home.arpa") {
            return true
        }

        // IPv4 checks
        let v4Parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if v4Parts.count == 4,
           let p0 = UInt8(v4Parts[0]), let p1 = UInt8(v4Parts[1]),
           let _ = UInt8(v4Parts[2]), let _ = UInt8(v4Parts[3]) {
            if p0 == 127 { return true }                                    // Loopback (127.0.0.0/8)
            if p0 == 10 { return true }                                     // RFC 1918 (10.0.0.0/8)
            if p0 == 172 && (16...31).contains(p1) { return true }          // RFC 1918 (172.16.0.0/12)
            if p0 == 192 && p1 == 168 { return true }                       // RFC 1918 (192.168.0.0/16)
            if p0 == 169 && p1 == 254 { return true }                       // Link-local (169.254.0.0/16)
            return false
        }

        // IPv6 checks
        if host == "::1" || host == "0:0:0:0:0:0:0:1" { return true }       // IPv6 Loopback
        if host.hasPrefix("fe80:") { return true }                         // Link-local
        if host.hasPrefix("fc") || host.hasPrefix("fd") { return true }     // Unique-local (fc00::/7)

        return false
    }

    public static func isValidBaseURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty else { return false }
        if scheme == "https" { return true }
        if scheme == "http" { return isLocalOrPrivateHost(host) }
        return false
    }

    public static func normalizedBaseURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              isValidBaseURL(url)
        else { return nil }
        return trimmed
    }
}
