// SPDX-License-Identifier: MIT

import Foundation
import Observation

/// Extractor closure injected from the Kokoro runtime package (decouples `MobileLLMUI` from compression packages).
public typealias KokoroArchiveExtractor = @Sendable (_ archiveURL: URL, _ destinationDir: URL) async throws -> Void

/// Lifecycle state of the downloadable Kokoro offline neural TTS bundle.
public enum KokoroInstallState: Equatable, Sendable {
    case notInstalled
    case downloading(progress: Double)
    case extracting
    case ready(sizeBytes: Int64)
    case failed(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Resolved file paths inside an extracted `kokoro-int8-multi-lang-v1_1` model folder.
public struct KokoroModelFiles: Sendable, Equatable {
    public let directoryURL: URL
    public let modelPath: String
    public let voicesPath: String
    public let tokensPath: String
    public let lexiconPaths: [String]
    public let dictDirPath: String?
}

/// Curated speaker presets for `kokoro-int8-multi-lang-v1_1` (103 speakers: EN + ZH).
public struct KokoroVoicePreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let sid: Int
    public let name: String
    public let language: String

    public init(id: String, sid: Int, name: String, language: String) {
        self.id = id
        self.sid = sid
        self.name = name
        self.language = language
    }

    public func toTTSVoiceInfo() -> TTSVoiceInfo {
        TTSVoiceInfo(id: id, name: name, language: language, qualityLabel: "Neural")
    }

    /// Default curated Chinese + English speaker presets for Kokoro v1.1-zh.
    public static let curated: [KokoroVoicePreset] = [
        // Chinese Female (zf_001 ... )
        KokoroVoicePreset(id: "zf_001", sid: 3, name: "中文女声 1 (zf_001)", language: "zh-CN"),
        KokoroVoicePreset(id: "zf_002", sid: 4, name: "中文女声 2 (zf_002)", language: "zh-CN"),
        KokoroVoicePreset(id: "zf_003", sid: 5, name: "中文女声 3 (zf_003)", language: "zh-CN"),
        KokoroVoicePreset(id: "zf_004", sid: 6, name: "中文女声 4 (zf_004)", language: "zh-CN"),
        KokoroVoicePreset(id: "zf_005", sid: 7, name: "中文女声 5 (zf_005)", language: "zh-CN"),
        // Chinese Male (zm_009 ... , sid 58...102 in Kokoro v1.1-zh)
        KokoroVoicePreset(id: "zm_009", sid: 58, name: "中文男声 1 (zm_009)", language: "zh-CN"),
        KokoroVoicePreset(id: "zm_010", sid: 59, name: "中文男声 2 (zm_010)", language: "zh-CN"),
        KokoroVoicePreset(id: "zm_011", sid: 60, name: "中文男声 3 (zm_011)", language: "zh-CN"),
        KokoroVoicePreset(id: "zm_012", sid: 61, name: "中文男声 4 (zm_012)", language: "zh-CN"),
        KokoroVoicePreset(id: "zm_013", sid: 62, name: "中文男声 5 (zm_013)", language: "zh-CN"),
        // English Female & Male
        KokoroVoicePreset(id: "af_maple", sid: 0, name: "English Female (Maple)", language: "en-US"),
        KokoroVoicePreset(id: "af_sol", sid: 1, name: "English Female (Sol)", language: "en-US"),
        KokoroVoicePreset(id: "bf_vale", sid: 2, name: "English Female (Vale)", language: "en-GB"),
    ]

    public static func resolveSID(voiceID: String?, fallbackChinese: Bool) -> Int {
        if let voiceID, let match = curated.first(where: { $0.id == voiceID }) {
            return match.sid
        }
        return fallbackChinese ? 3 : 0
    }
}

/// Manages downloading, extracting, verifying, and removing the offline Kokoro TTS bundle.
@MainActor
@Observable
public final class KokoroModelManager {
    public nonisolated static let defaultDownloadURL = URL(
        string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-multi-lang-v1_1.tar.bz2"
    )!
    public nonisolated static let bundleFolderName = "kokoro-int8-multi-lang-v1_1"

    public private(set) var state: KokoroInstallState = .notInstalled
    public let rootDirectory: URL
    /// Optional hook fired right before extracting the compressed bundle so resident LLM memory can be freed.
    public var onWillExtract: (@MainActor () async -> Void)?
    private let downloadURL: URL
    private let extractor: KokoroArchiveExtractor?

    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var activeDownloadDelegate: DownloadDelegate?

    public init(
        rootDirectory: URL? = nil,
        downloadURL: URL? = nil,
        extractor: KokoroArchiveExtractor? = nil
    ) {
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.rootDirectory = appSupport.appendingPathComponent("TTS", isDirectory: true)
        }
        self.downloadURL = downloadURL ?? Self.defaultDownloadURL
        self.extractor = extractor
        refreshState()
    }

    public var modelDirectory: URL {
        rootDirectory.appendingPathComponent(Self.bundleFolderName, isDirectory: true)
    }

    public func refreshState() {
        if let files = resolveInstalledFiles() {
            let bytes = Self.directorySize(at: files.directoryURL)
            state = .ready(sizeBytes: bytes)
        } else if case .downloading = state {
            return
        } else if case .extracting = state {
            return
        } else {
            state = .notInstalled
        }
    }

    public func resolveInstalledFiles() -> KokoroModelFiles? {
        let fm = FileManager.default
        let candidateDirs = [
            modelDirectory,
            modelDirectory.appendingPathComponent(Self.bundleFolderName, isDirectory: true),
        ]

        for dir in candidateDirs {
            let modelCandidates = ["model.int8.onnx", "model.onnx"]
            guard let modelName = modelCandidates.first(where: { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }) else {
                continue
            }
            let voicesURL = dir.appendingPathComponent("voices.bin")
            let tokensURL = dir.appendingPathComponent("tokens.txt")
            guard fm.fileExists(atPath: voicesURL.path),
                  fm.fileExists(atPath: tokensURL.path) else {
                continue
            }

            let lexiconNames = ["lexicon-us-en.txt", "lexicon-zh.txt"]
            let lexiconPaths = lexiconNames
                .map { dir.appendingPathComponent($0).path }
                .filter { fm.fileExists(atPath: $0) }

            let dictDir = dir.appendingPathComponent("dict", isDirectory: true)
            let hasDict = fm.fileExists(atPath: dictDir.path)

            return KokoroModelFiles(
                directoryURL: dir,
                modelPath: dir.appendingPathComponent(modelName).path,
                voicesPath: voicesURL.path,
                tokensPath: tokensURL.path,
                lexiconPaths: lexiconPaths,
                dictDirPath: hasDict ? dictDir.path : nil
            )
        }
        return nil
    }

    public func startDownload() {
        guard downloadTask == nil else { return }
        guard let extractor else {
            state = .failed("Archive extractor unavailable.")
            return
        }

        state = .downloading(progress: 0)
        let targetDir = modelDirectory
        let rootDir = rootDirectory
        let sourceURL = downloadURL

        downloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.downloadTask = nil
                self.activeDownloadDelegate = nil
            }

            do {
                let archiveURL = try await self.downloadFile(from: sourceURL)
                defer { try? FileManager.default.removeItem(at: archiveURL) }

                try Task.checkCancellation()
                self.state = .extracting
                await self.onWillExtract?()

                let tempExtractDir = rootDir.appendingPathComponent("kokoro-staging-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: tempExtractDir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: tempExtractDir) }

                try await extractor(archiveURL, tempExtractDir)
                try Task.checkCancellation()

                // Normalize nested folder (tar.bz2 usually extracts a top-level `kokoro-int8-multi-lang-v1_1/` directory).
                let nestedDir = tempExtractDir.appendingPathComponent(Self.bundleFolderName, isDirectory: true)
                let sourceFolder = FileManager.default.fileExists(atPath: nestedDir.path) ? nestedDir : tempExtractDir

                if FileManager.default.fileExists(atPath: targetDir.path) {
                    try FileManager.default.removeItem(at: targetDir)
                }
                try FileManager.default.moveItem(at: sourceFolder, to: targetDir)

                if let files = self.resolveInstalledFiles() {
                    self.state = .ready(sizeBytes: Self.directorySize(at: files.directoryURL))
                } else {
                    try? FileManager.default.removeItem(at: targetDir)
                    self.state = .failed("Downloaded archive is missing required Kokoro model files.")
                }
            } catch is CancellationError {
                self.refreshState()
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        activeDownloadDelegate?.cancel()
        activeDownloadDelegate = nil
        refreshState()
    }

    public func deleteModel() {
        cancelDownload()
        try? FileManager.default.removeItem(at: modelDirectory)
        state = .notInstalled
    }

    // MARK: - Helpers

    private func downloadFile(from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate(
                onProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        if case .downloading = self?.state {
                            self?.state = .downloading(progress: progress)
                        }
                    }
                },
                onCompletion: { result in
                    continuation.resume(with: result)
                }
            )
            self.activeDownloadDelegate = delegate
            delegate.start(url: url)
        }
    }

    private nonisolated static func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               values.isRegularFile == true,
               let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let onProgress: @Sendable (Double) -> Void
        private let onCompletion: @Sendable (Result<URL, Error>) -> Void
        private var session: URLSession?
        private var task: URLSessionDownloadTask?
        private var finished = false
        private let lock = NSLock()

        init(
            onProgress: @escaping @Sendable (Double) -> Void,
            onCompletion: @escaping @Sendable (Result<URL, Error>) -> Void
        ) {
            self.onProgress = onProgress
            self.onCompletion = onCompletion
        }

        func start(url: URL) {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 600
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.session = session
            let task = session.downloadTask(with: url)
            self.task = task
            task.resume()
        }

        func cancel() {
            task?.cancel()
            finish(with: .failure(CancellationError()))
        }

        private func finish(with result: Result<URL, Error>) {
            lock.lock()
            let alreadyFinished = finished
            finished = true
            lock.unlock()
            guard !alreadyFinished else { return }
            session?.finishTasksAndInvalidate()
            session = nil
            onCompletion(result)
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let progress = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
            onProgress(progress)
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            let tempCopy = FileManager.default.temporaryDirectory
                .appendingPathComponent("kokoro-\(UUID().uuidString).tar.bz2")
            do {
                if FileManager.default.fileExists(atPath: tempCopy.path) {
                    try FileManager.default.removeItem(at: tempCopy)
                }
                try FileManager.default.moveItem(at: location, to: tempCopy)
                finish(with: .success(tempCopy))
            } catch {
                finish(with: .failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                finish(with: .failure(error))
            }
        }
    }
}
