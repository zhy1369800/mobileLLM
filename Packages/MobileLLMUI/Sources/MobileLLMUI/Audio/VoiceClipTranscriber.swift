// SPDX-License-Identifier: MIT

import Foundation
import Speech

/// Errors surfaced when auto-transcribing an imported or recorded voice-clone reference clip.
public enum VoiceClipTranscriptionError: LocalizedError, Sendable, Equatable {
    case permissionDenied
    case recognizerUnavailable
    case emptyTranscript
    case timedOut
    case recognitionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Speech recognition permission was denied. You can still type the reference script manually."
        case .recognizerUnavailable:
            return "On-device speech recognizer is unavailable for this language. You can type the reference script manually."
        case .emptyTranscript:
            return "No speech was detected in this audio clip. You can type the reference script manually."
        case .timedOut:
            return "Auto-transcription timed out. You can try again or type the reference script manually."
        case .recognitionFailed(let reason):
            return "Auto-transcription failed (\(reason)). You can type the reference script manually."
        }
    }
}

/// Tracks the origin of the reference script draft inside `VoiceCloneSheet` so built-in sample text
/// is never accidentally bound to an imported audio clip, while user-entered text is preserved.
public struct VoiceCloneTranscriptDraft: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case empty
        case sampleScript
        case autoTranscribed
        case userEdited
    }

    public private(set) var text: String
    public private(set) var source: Source

    public init(initialSampleScript: String? = VoiceSampleRecorder.sampleScripts.first?.text) {
        let initial = initialSampleScript ?? ""
        self.text = initial
        self.source = initial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .sampleScript
    }

    public static func isBuiltInSampleScript(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return VoiceSampleRecorder.sampleScripts.contains {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
        }
    }

    public mutating func applySampleScript(_ script: String) {
        text = script
        source = script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .sampleScript
    }

    public mutating func userDidEdit(to newText: String) {
        text = newText
        source = newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .userEdited
    }

    /// Clears built-in sample scripts (or stale text from a previous import) before importing audio.
    /// Returns `true` when auto-transcription should run to populate the field.
    @discardableResult
    public mutating func prepareForImportedAudio(replacingExistingImport: Bool) -> Bool {
        if !replacingExistingImport && source == .userEdited && !Self.isBuiltInSampleScript(text) {
            return false
        }
        text = ""
        source = .empty
        return true
    }

    @discardableResult
    public mutating func applyAutoTranscription(_ recognized: String, overwriteUserText: Bool) -> Bool {
        let trimmed = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if !overwriteUserText && source == .userEdited {
            return false
        }
        text = trimmed
        source = .autoTranscribed
        return true
    }

    public mutating func clearAudioClip() {
        if source == .autoTranscribed {
            text = ""
            source = .empty
        }
    }

    public mutating func resetAfterSave() {
        text = ""
        source = .empty
    }
}

/// On-device `SFSpeechURLRecognitionRequest` wrapper for transcribing short voice-clone audio clips.
public enum VoiceClipTranscriber {
    public static let languageOptions: [(id: String?, label: String)] = [
        (nil, "System language"),
        ("zh-CN", "中文（普通话）"),
        ("en-US", "English"),
    ]

    public static func transcribe(
        url: URL,
        localeIdentifier: String? = nil,
        timeout: Duration = .seconds(15)
    ) async throws -> String {
        try Task.checkCancellation()

        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized:
            break
        case .denied, .restricted:
            throw VoiceClipTranscriptionError.permissionDenied
        case .notDetermined:
            guard await requestSpeechAuthorization() else {
                throw VoiceClipTranscriptionError.permissionDenied
            }
        @unknown default:
            guard await requestSpeechAuthorization() else {
                throw VoiceClipTranscriptionError.permissionDenied
            }
        }

        try Task.checkCancellation()

        let recognizer: SFSpeechRecognizer? = if let localeIdentifier {
            SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        } else {
            SFSpeechRecognizer()
        }
        guard let recognizer, recognizer.isAvailable else {
            throw VoiceClipTranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let box = RecognitionSessionBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.start(continuation: continuation, timeout: timeout) {
                    recognizer.recognitionTask(with: request) { result, error in
                        box.handleResult(
                            transcript: result?.bestTranscription.formattedString,
                            isFinal: result?.isFinal ?? false,
                            error: error
                        )
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    private static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { auth in
                continuation.resume(returning: auth == .authorized)
            }
        }
    }

    /// Thread-safe one-shot coordinator ensuring `CheckedContinuation` is resumed at most once
    /// across `SFSpeechRecognitionTask` callbacks, cancellation, and timeouts.
    private final class RecognitionSessionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String, Error>?
        private var task: SFSpeechRecognitionTask?
        private var timeoutTask: Task<Void, Never>?
        private var latestTranscript: String = ""
        private var completed = false

        func start(
            continuation: CheckedContinuation<String, Error>,
            timeout: Duration,
            createTask: () -> SFSpeechRecognitionTask
        ) {
            lock.lock()
            if completed {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            self.timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                self?.handleTimeout()
            }
            lock.unlock()

            let recognitionTask = createTask()

            lock.lock()
            if completed {
                lock.unlock()
                recognitionTask.cancel()
                return
            }
            self.task = recognitionTask
            lock.unlock()
        }

        func handleResult(transcript: String?, isFinal: Bool, error: Error?) {
            var updatedTranscript = ""
            lock.lock()
            if let transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                latestTranscript = transcript
            }
            updatedTranscript = latestTranscript
            lock.unlock()

            if isFinal {
                let trimmed = updatedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    finish(with: .failure(VoiceClipTranscriptionError.emptyTranscript), cancelTask: false)
                } else {
                    finish(with: .success(trimmed), cancelTask: false)
                }
            } else if let error {
                let trimmed = updatedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    finish(with: .success(trimmed), cancelTask: true)
                } else {
                    finish(with: .failure(VoiceClipTranscriptionError.recognitionFailed(error.localizedDescription)), cancelTask: true)
                }
            }
        }

        private func handleTimeout() {
            lock.lock()
            let trimmed = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            lock.unlock()

            if !trimmed.isEmpty {
                finish(with: .success(trimmed), cancelTask: true)
            } else {
                finish(with: .failure(VoiceClipTranscriptionError.timedOut), cancelTask: true)
            }
        }

        func cancel() {
            finish(with: .failure(CancellationError()), cancelTask: true)
        }

        private func finish(with result: Result<String, Error>, cancelTask: Bool) {
            let stolenContinuation: CheckedContinuation<String, Error>?
            let stolenTask: SFSpeechRecognitionTask?
            let stolenTimeout: Task<Void, Never>?

            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            completed = true
            stolenContinuation = continuation
            continuation = nil
            stolenTask = task
            task = nil
            stolenTimeout = timeoutTask
            timeoutTask = nil
            lock.unlock()

            stolenTimeout?.cancel()
            if cancelTask {
                stolenTask?.cancel()
            }
            stolenContinuation?.resume(with: result)
        }
    }
}
