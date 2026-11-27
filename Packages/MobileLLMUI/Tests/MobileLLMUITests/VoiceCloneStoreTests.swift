// SPDX-License-Identifier: MIT

import XCTest
import AppRuntime
@testable import LLMCore
@testable import MobileLLMUI

@MainActor
final class VoiceCloneStoreTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appending(component: "voice-clone-store-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        super.tearDown()
    }

    func testAddUpdateDeleteAndReloadProfiles() throws {
        let storeDir = tempRoot.appending(component: "voice_clones")
        let sourceAudio = tempRoot.appending(component: "sample.wav")
        try Data("RIFFstub".utf8).write(to: sourceAudio)

        let store = VoiceCloneStore(directory: storeDir)
        XCTAssertTrue(store.profiles.isEmpty)

        let added = try store.addProfile(
            name: "  Alice  ",
            sourceAudioURL: sourceAudio,
            referenceTranscript: "  你好世界  ",
            durationSeconds: 6.4
        )
        XCTAssertTrue(ClonedVoiceProfile.isClonedVoiceID(added.id))
        XCTAssertEqual(added.name, "Alice")
        XCTAssertEqual(added.referenceTranscript, "你好世界")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(for: added).path))

        try store.updateProfile(id: added.id, name: "Alice V2", referenceTranscript: "Hello again")
        let reloaded = VoiceCloneStore(directory: storeDir)
        XCTAssertEqual(reloaded.profiles.count, 1)
        XCTAssertEqual(reloaded.profiles.first?.name, "Alice V2")
        XCTAssertEqual(reloaded.profiles.first?.referenceTranscript, "Hello again")

        var deletedIDs: [String] = []
        reloaded.onProfileDeleted = { deletedIDs.append($0) }
        reloaded.delete(id: added.id)

        XCTAssertTrue(reloaded.profiles.isEmpty)
        XCTAssertEqual(deletedIDs, [added.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: reloaded.audioURL(for: added).path))

        _ = try reloaded.addProfile(
            name: "Temp",
            sourceAudioURL: sourceAudio,
            referenceTranscript: "",
            durationSeconds: 3.0
        )
        try reloaded.eraseAllData()
        XCTAssertTrue(reloaded.profiles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeDir.path))
    }

    func testAppContainerResetsActiveClonedVoiceOnDelete() throws {
        let suite = "voice-clone-container-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults, fallbackDefaultModelID: "bonsai-8b", keychain: nil)
        let container = AppContainer(
            engine: MockLLMEngine(),
            downloadBase: tempRoot.appending(component: "downloads"),
            downloader: { _, _, _, progress in progress(1) },
            settings: settings,
            conversationStore: ConversationStore(directory: tempRoot.appending(component: "conversations")),
            installProbe: { _, _ in false },
            availableMemory: { .max },
            openAICredentials: EphemeralOpenAICredentialStore(),
            mcpDiscovery: MCPDiscoveryCache(defaults: defaults)
        )

        let sourceAudio = tempRoot.appending(component: "clip.wav")
        try Data("RIFFstub".utf8).write(to: sourceAudio)
        let profile = try container.voiceClones.addProfile(
            name: "Clone",
            sourceAudioURL: sourceAudio,
            referenceTranscript: "Test",
            durationSeconds: 4.5
        )
        container.settings.localMLXVoiceID = profile.id
        container.settings.ttsEngineKind = .localMLX

        container.voiceClones.delete(id: profile.id)

        XCTAssertFalse(ClonedVoiceProfile.isClonedVoiceID(container.settings.localMLXVoiceID))
        XCTAssertEqual(container.settings.localMLXVoiceID, LocalTTSModelCatalog.defaultVoiceID)
    }

    func testVoiceCloneTranscriptDraftImportAndEditTransitions() {
        var draft = VoiceCloneTranscriptDraft(initialSampleScript: "Sample text")
        XCTAssertEqual(draft.text, "Sample text")
        XCTAssertEqual(draft.source, .sampleScript)

        // Built-in sample script must be cleared when importing audio so mismatched text isn't bound.
        let defaultScript = VoiceSampleRecorder.sampleScripts.first?.text ?? ""
        draft.applySampleScript(defaultScript)
        XCTAssertEqual(draft.source, .sampleScript)
        XCTAssertTrue(draft.prepareForImportedAudio(replacingExistingImport: false))
        XCTAssertEqual(draft.text, "")
        XCTAssertEqual(draft.source, .empty)

        // Auto-transcription trims whitespace and records .autoTranscribed source.
        XCTAssertTrue(draft.applyAutoTranscription("  你好世界。  ", overwriteUserText: false))
        XCTAssertEqual(draft.text, "你好世界。")
        XCTAssertEqual(draft.source, .autoTranscribed)

        // User edits switch to .userEdited; passive auto-transcription won't overwrite, explicit overwrite will.
        draft.userDidEdit(to: "自定义台词")
        XCTAssertEqual(draft.source, .userEdited)
        XCTAssertFalse(draft.applyAutoTranscription("识别结果", overwriteUserText: false))
        XCTAssertEqual(draft.text, "自定义台词")
        XCTAssertTrue(draft.applyAutoTranscription("识别结果", overwriteUserText: true))
        XCTAssertEqual(draft.text, "识别结果")
        XCTAssertEqual(draft.source, .autoTranscribed)

        // Pre-typed user text before first import is preserved and suppresses auto-overwrite.
        var preTyped = VoiceCloneTranscriptDraft(initialSampleScript: "")
        preTyped.userDidEdit(to: "用户提前粘贴的台词")
        XCTAssertFalse(preTyped.prepareForImportedAudio(replacingExistingImport: false))
        XCTAssertEqual(preTyped.text, "用户提前粘贴的台词")
        XCTAssertEqual(preTyped.source, .userEdited)

        // Replacing an existing imported clip clears even user-edited text from the previous clip.
        XCTAssertTrue(preTyped.prepareForImportedAudio(replacingExistingImport: true))
        XCTAssertEqual(preTyped.text, "")
        XCTAssertEqual(preTyped.source, .empty)

        // Clearing an audio clip clears auto-transcribed text, but preserves user-edited or sample text.
        preTyped.applyAutoTranscription("自动识别内容", overwriteUserText: false)
        preTyped.clearAudioClip()
        XCTAssertEqual(preTyped.text, "")
        XCTAssertEqual(preTyped.source, .empty)

        preTyped.userDidEdit(to: "手动文本")
        preTyped.clearAudioClip()
        XCTAssertEqual(preTyped.text, "手动文本")
        XCTAssertEqual(preTyped.source, .userEdited)

        preTyped.resetAfterSave()
        XCTAssertEqual(preTyped.text, "")
        XCTAssertEqual(preTyped.source, .empty)
    }
}
