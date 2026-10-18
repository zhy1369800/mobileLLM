// SPDX-License-Identifier: MIT

import Foundation

/// Centralized configuration for Hugging Face network endpoints, supporting the official hub
/// and domestic mirrors (e.g. hf-mirror.com) for high-speed, reliable downloads in restricted networks.
public enum HuggingFaceEndpoint: Sendable {
    public static let officialHost = "huggingface.co"
    public static let mirrorHost = "hf-mirror.com"

    public static let envKey = "MOBILELLM_HF_HOST"
    public static let userDefaultsKey = "huggingFaceUseMirror"

    /// Resolved active host based on environment variable, user preference, or default (mirror enabled).
    public static var currentHost: String {
        if let env = ProcessInfo.processInfo.environment[envKey], !env.isEmpty {
            return env
        }
        if UserDefaults.standard.object(forKey: userDefaultsKey) != nil {
            return UserDefaults.standard.bool(forKey: userDefaultsKey) ? mirrorHost : officialHost
        }
        // Defaults to China domestic mirror for out-of-the-box reliability.
        return mirrorHost
    }
}
