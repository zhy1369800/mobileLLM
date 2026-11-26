// SPDX-License-Identifier: MIT

import XCTest
import AppRuntime
@testable import LLMCore
@testable import MobileLLMUI

@MainActor
final class LocalTTSModelManagerTests: XCTestCase {
    private var tempBase: URL!

    override func setUp() {
        super.setUp()
        tempBase = FileManager.default.temporaryDirectory
            .appending(component: "local-tts-manager-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempBase {
            try? FileManager.default.removeItem(at: tempBase)
        }
        super.tearDown()
    }

    func testCatalogPrioritizesCosyVoice3AndIncludesQwen3TTS() {
        XCTAssertEqual(LocalTTSModelCatalog.all.map(\.id), ["cosyvoice3-0.5b", "qwen3-tts-12hz-0.6b-customvoice"])
        XCTAssertEqual(LocalTTSModelCatalog.defaultModel.id, "cosyvoice3-0.5b")
        XCTAssertEqual(LocalTTSModelCatalog.defaultVariant.id, "cosyvoice3-0.5b-4bit")
        XCTAssertEqual(LocalTTSModelCatalog.defaultVoiceID, "default_zh")

        let cosy = LocalTTSModelCatalog.cosyVoice305B
        XCTAssertEqual(cosy.variants.count, 2)
        XCTAssertEqual(cosy.defaultQuant, .int4)
        XCTAssertTrue(cosy.presetVoices.contains { $0.id == "default_zh" })
        XCTAssertNotNil(LocalTTSModelCatalog.variant(id: "cosyvoice3-0.5b-8bit"))

        let qwen = LocalTTSModelCatalog.qwen3TTS06B
        XCTAssertEqual(qwen.variants.count, 2)
        XCTAssertTrue(qwen.presetVoices.contains { $0.id == "Vivian" })
    }

    func testDownloadInstallsVariantAndDeleteNotifiesAndRemovesFiles() async {
        let variant = LocalTTSModelCatalog.defaultVariant
        let base = tempBase!

        let manager = LocalTTSModelManager(
            downloadBase: base,
            downloader: { _, _, _, progress in
                progress(0.5)
                let root = ModelDownloader(downloadBase: base).localURL(repoId: variant.huggingFaceRepo)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data("weights".utf8).write(to: root.appending(component: "model.safetensors"))
                progress(1.0)
            },
            installProbe: { candidate, _ in
                let root = ModelDownloader(downloadBase: base).localURL(repoId: candidate.huggingFaceRepo)
                return FileManager.default.fileExists(atPath: root.appending(component: "model.safetensors").path)
            }
        )

        var deletedIDs: [String] = []
        manager.onModelDeleted = { deletedIDs.append($0) }

        XCTAssertFalse(manager.isInstalled(variant))
        XCTAssertEqual(manager.installedBytes, 0)

        manager.download(variant)
        for _ in 0..<25 where manager.isDownloading(variant) {
            await Task.yield()
        }

        XCTAssertTrue(manager.isInstalled(variant))
        XCTAssertGreaterThan(manager.installedBytes, 0)
        XCTAssertNil(manager.downloadState(variant))

        manager.delete(variant)
        XCTAssertFalse(manager.isInstalled(variant))
        XCTAssertEqual(manager.installedBytes, 0)
        XCTAssertEqual(deletedIDs, [variant.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.localDirectory(for: variant).path))
    }

    func testPauseMarksPausedAndEraseRemovesAllInstalledVoiceDirectories() async throws {
        let base = tempBase!
        let v4 = LocalTTSModelCatalog.defaultModel.variant(for: .int4)!
        let v8 = LocalTTSModelCatalog.defaultModel.variant(for: .int8)!

        let manager = LocalTTSModelManager(
            downloadBase: base,
            downloader: { _, _, _, progress in
                progress(0.25)
                try await Task.sleep(for: .seconds(10))
            },
            installProbe: { candidate, _ in
                let root = ModelDownloader(downloadBase: base).localURL(repoId: candidate.huggingFaceRepo)
                return FileManager.default.fileExists(atPath: root.appending(component: "model.safetensors").path)
            }
        )

        manager.download(v4)
        for _ in 0..<10 where manager.downloadState(v4) == nil {
            await Task.yield()
        }
        manager.pause(v4)
        for _ in 0..<20 where manager.isDownloading(v4) {
            await Task.yield()
        }
        XCTAssertEqual(manager.downloadState(v4)?.isPaused, true)

        for v in [v4, v8] {
            let root = manager.localDirectory(for: v)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("stub".utf8).write(to: root.appending(component: "model.safetensors"))
        }
        manager.refreshInstalled()
        XCTAssertTrue(manager.isInstalled(v4))
        XCTAssertTrue(manager.isInstalled(v8))

        try await manager.eraseDownloadedData()
        XCTAssertTrue(manager.installed.isEmpty)
        XCTAssertEqual(manager.installedBytes, 0)
    }

    func testPauseResumeIgnoresStaleProgressAndInitializesMeter() async {
        let variant = LocalTTSModelCatalog.defaultVariant
        let base = tempBase!

        actor AttemptCounter {
            private var count = 0
            private var resumeSecond: CheckedContinuation<Void, Never>?
            private var released = false

            func nextAttempt() -> Int {
                count += 1
                return count
            }

            func waitForSecondContinuation() async {
                if released { return }
                await withCheckedContinuation { cont in
                    resumeSecond = cont
                }
            }

            func releaseSecond() {
                released = true
                resumeSecond?.resume()
                resumeSecond = nil
            }
        }

        let counter = AttemptCounter()
        let manager = LocalTTSModelManager(
            downloadBase: base,
            downloader: { _, _, _, progress in
                let attempt = await counter.nextAttempt()
                if attempt == 1 {
                    progress(0.1)
                    do {
                        try await Task.sleep(for: .seconds(10))
                    } catch {
                        progress(0.05)
                        throw URLError(.cancelled)
                    }
                } else {
                    progress(0.5)
                    await counter.waitForSecondContinuation()
                    let root = ModelDownloader(downloadBase: base).localURL(repoId: variant.huggingFaceRepo)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    try Data("weights".utf8).write(to: root.appending(component: "model.safetensors"))
                    progress(1.0)
                }
            },
            installProbe: { candidate, _ in
                let root = ModelDownloader(downloadBase: base).localURL(repoId: candidate.huggingFaceRepo)
                return FileManager.default.fileExists(atPath: root.appending(component: "model.safetensors").path)
            }
        )

        manager.download(variant)
        for _ in 0..<25 where manager.downloadState(variant)?.fraction ?? 0 < 0.1 {
            await Task.yield()
        }

        manager.pause(variant)
        for _ in 0..<25 where manager.downloadState(variant)?.isPaused != true {
            await Task.yield()
        }
        XCTAssertEqual(manager.downloadState(variant)?.isPaused, true)
        XCTAssertNil(manager.downloadState(variant)?.error)

        manager.download(variant)
        XCTAssertEqual(manager.downloadState(variant)?.fraction, 0.1)
        XCTAssertEqual(manager.downloadState(variant)?.isPaused, false)
        for _ in 0..<25 where manager.downloadState(variant)?.fraction ?? 0 < 0.5 {
            await Task.yield()
        }

        let midState = manager.downloadState(variant)
        XCTAssertEqual(midState?.meter.totalBytes, variant.approximateBytes)
        XCTAssertGreaterThanOrEqual(midState?.fraction ?? 0, 0.5)

        await counter.releaseSecond()
        for _ in 0..<25 where manager.isDownloading(variant) {
            await Task.yield()
        }

        XCTAssertTrue(manager.isInstalled(variant))
        XCTAssertNil(manager.downloadState(variant))
        XCTAssertGreaterThan(manager.installedBytes, 0)
    }

    func testAppContainerDeleteFallsBackAndReconcilesLocalMLXVoiceID() {
        let suite = "local-tts-container-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let cosy4 = LocalTTSModelCatalog.cosyVoice305B.variant(for: .int4)!
        let qwen4 = LocalTTSModelCatalog.qwen3TTS06B.variant(for: .int4)!

        let settings = AppSettings(defaults: defaults, fallbackDefaultModelID: "bonsai-8b", keychain: nil)
        settings.ttsEngineKind = .localMLX
        settings.localMLXModelVariantID = cosy4.id
        settings.localMLXVoiceID = "default_zh"

        let container = AppContainer(
            engine: MockLLMEngine(),
            downloadBase: tempBase.appending(component: "downloads"),
            downloader: { _, _, _, progress in progress(1) },
            settings: settings,
            conversationStore: ConversationStore(directory: tempBase.appending(component: "conversations")),
            installProbe: { _, _ in false },
            availableMemory: { .max },
            openAICredentials: EphemeralOpenAICredentialStore(),
            mcpDiscovery: MCPDiscoveryCache(defaults: defaults),
            voiceInstallProbe: { variant, base in
                let root = ModelDownloader(downloadBase: base).localURL(repoId: variant.huggingFaceRepo)
                return FileManager.default.fileExists(atPath: root.appending(component: "model.safetensors").path)
            }
        )

        for variant in [cosy4, qwen4] {
            let root = container.voiceModels.localDirectory(for: variant)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? Data("stub".utf8).write(to: root.appending(component: "model.safetensors"))
        }
        container.voiceModels.refreshInstalled()
        XCTAssertTrue(container.voiceModels.isInstalled(cosy4))
        XCTAssertTrue(container.voiceModels.isInstalled(qwen4))

        container.voiceModels.delete(cosy4)

        XCTAssertFalse(container.voiceModels.isInstalled(cosy4))
        XCTAssertEqual(container.settings.localMLXModelVariantID, qwen4.id)
        XCTAssertEqual(container.settings.localMLXVoiceID, "Vivian")
    }
}
