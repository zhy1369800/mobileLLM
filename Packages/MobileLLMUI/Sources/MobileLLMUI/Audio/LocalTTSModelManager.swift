// SPDX-License-Identifier: MIT

import Foundation
import Observation
import AppRuntime
import LLMCore

/// Manages downloads, install checks, and deletions for curated local MLX voice models
/// (`LocalTTSModelCatalog`) independently of the chat LLM residency in `ModelManager`.
@MainActor
@Observable
public final class LocalTTSModelManager {
    public typealias InstallProbe = @Sendable (LocalTTSModelVariant, URL) -> Bool

    public let catalog: [LocalTTSModel] = LocalTTSModelCatalog.all
    public private(set) var installed: Set<String> = []
    public private(set) var installedBytes: Int64 = 0
    public private(set) var downloads: [String: VariantDownload] = [:]
    public private(set) var isErasingDownloadedData: Bool = false

    @ObservationIgnored public var onModelDeleted: ((_ variantID: String) -> Void)?

    private let downloadBase: URL
    private let downloader: ModelManager.Downloader
    private let installProbe: InstallProbe
    @ObservationIgnored private var downloadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var downloadGenerations: [String: UInt64] = [:]

    public init(
        downloadBase: URL,
        downloader: @escaping ModelManager.Downloader,
        installProbe: InstallProbe? = nil
    ) {
        self.downloadBase = downloadBase
        self.downloader = downloader
        self.installProbe = installProbe ?? { variant, base in
            ModelDownloader(downloadBase: base).isDownloaded(
                repoId: variant.huggingFaceRepo,
                revision: variant.revision
            )
        }
        refreshInstalled()
    }

    public var hasActiveDownloads: Bool {
        downloads.values.contains { !$0.isPaused && $0.error == nil }
    }

    public func localDirectory(for variant: LocalTTSModelVariant) -> URL {
        ModelDownloader(downloadBase: downloadBase).localURL(repoId: variant.huggingFaceRepo)
    }

    public func isInstalled(_ variant: LocalTTSModelVariant) -> Bool {
        installed.contains(variant.id)
    }

    public func isDownloading(_ variant: LocalTTSModelVariant) -> Bool {
        guard let state = downloads[variant.id] else { return false }
        return !state.isPaused && state.error == nil
    }

    public func downloadState(_ variant: LocalTTSModelVariant) -> VariantDownload? {
        downloads[variant.id]
    }

    public func refreshInstalled() {
        var next = Set<String>()
        var totalBytes: Int64 = 0
        for model in catalog {
            for variant in model.variants {
                if installProbe(variant, downloadBase) {
                    next.insert(variant.id)
                    totalBytes += Self.directorySize(at: localDirectory(for: variant))
                }
            }
        }
        installed = next
        installedBytes = totalBytes
    }

    private func nextGeneration(for variantID: String) -> UInt64 {
        let next = (downloadGenerations[variantID] ?? 0) &+ 1
        downloadGenerations[variantID] = next
        return next
    }

    public func download(_ variant: LocalTTSModelVariant) {
        let variantID = variant.id
        guard !isErasingDownloadedData,
              !isDownloading(variant),
              downloadTasks[variantID] == nil else { return }

        let generation = nextGeneration(for: variantID)

        let repoId = variant.huggingFaceRepo
        let revision = variant.revision
        let approxBytes = variant.approximateBytes

        var initial = downloads[variantID] ?? VariantDownload()
        initial.isPaused = false
        initial.isPausing = false
        initial.error = nil
        initial.meter.start(total: approxBytes)
        downloads[variantID] = initial

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.downloadGenerations[variantID] == generation {
                    self.downloadTasks[variantID] = nil
                }
            }

            do {
                try await self.downloader(repoId, revision, []) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.downloadGenerations[variantID] == generation,
                              var state = self.downloads[variantID],
                              !state.isPaused,
                              !state.isPausing,
                              state.error == nil else { return }
                        let clamped = min(max(fraction, 0), 1)
                        state.fraction = clamped
                        state.meter.update(fraction: clamped)
                        self.downloads[variantID] = state
                    }
                }
                guard self.downloadGenerations[variantID] == generation else { return }
                if Task.isCancelled {
                    if var state = self.downloads[variantID] {
                        state.isPausing = false
                        state.isPaused = true
                        state.error = nil
                        self.downloads[variantID] = state
                    }
                } else {
                    self.downloads[variantID] = nil
                    self.refreshInstalled()
                }
            } catch {
                guard self.downloadGenerations[variantID] == generation else { return }
                if var state = self.downloads[variantID] {
                    state.isPausing = false
                    if Task.isCancelled || error is CancellationError {
                        state.isPaused = true
                        state.error = nil
                    } else {
                        state.isPaused = false
                        state.error = error.localizedDescription
                    }
                    self.downloads[variantID] = state
                }
            }
        }
        downloadTasks[variantID] = task
    }

    public func pause(_ variant: LocalTTSModelVariant) {
        let variantID = variant.id
        guard let task = downloadTasks[variantID] else { return }
        if var state = downloads[variantID] {
            state.isPausing = true
            downloads[variantID] = state
        }
        task.cancel()
    }

    public func delete(_ variant: LocalTTSModelVariant) {
        let variantID = variant.id
        _ = nextGeneration(for: variantID)
        if let task = downloadTasks[variantID] {
            task.cancel()
            downloadTasks[variantID] = nil
        }
        downloads[variantID] = nil
        let root = localDirectory(for: variant)
        try? FileManager.default.removeItem(at: root)
        refreshInstalled()
        onModelDeleted?(variantID)
    }

    public func eraseDownloadedData() async throws {
        isErasingDownloadedData = true
        defer { isErasingDownloadedData = false }

        for key in Array(downloadTasks.keys) {
            _ = nextGeneration(for: key)
        }
        let runningTasks = Array(downloadTasks.values)
        for task in runningTasks {
            task.cancel()
        }
        for task in runningTasks {
            await task.value
        }
        downloadTasks.removeAll()
        downloads.removeAll()

        var failures: [String] = []
        let fm = FileManager.default
        for model in catalog {
            for variant in model.variants {
                let root = localDirectory(for: variant)
                guard fm.fileExists(atPath: root.path) else { continue }
                do {
                    try fm.removeItem(at: root)
                } catch {
                    failures.append("\(model.displayName) (\(variant.quant.displayName)): \(error.localizedDescription)")
                }
            }
        }

        refreshInstalled()
        if !failures.isEmpty {
            throw ModelDataDeletionError(failures: failures)
        }
    }

    private static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return 0 }
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}
