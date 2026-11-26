// SPDX-License-Identifier: MIT

import SwiftUI
import UniformTypeIdentifiers
import AppUI

/// Manage saved zero-shot voice clones and record or import new 3–25s reference clips for CosyVoice3.
struct VoiceCloneSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var voiceClones: VoiceCloneStore
    @Bindable var settings: AppSettings
    let isCosyVoiceActive: Bool
    let installedCosyVoiceVariantID: String?

    @State private var recorder = VoiceSampleRecorder()
    @State private var draftName: String = ""
    @State private var draftTranscript: String = VoiceSampleRecorder.sampleScripts.first?.text ?? ""
    @State private var importedStagingURL: URL?
    @State private var importedDuration: Double = 0
    @State private var showAudioImporter = false
    @State private var statusError: String?

    private var activeSourceURL: URL? {
        importedStagingURL ?? recorder.recordedURL
    }

    private var activeSourceDuration: Double {
        importedStagingURL != nil ? importedDuration : recorder.recordedDuration
    }

    private var canSave: Bool {
        !draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && activeSourceURL != nil
            && activeSourceDuration >= 1.5
            && activeSourceDuration <= 30.0
            && !recorder.isRecording
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    if !isCosyVoiceActive {
                        Text("Zero-shot voice cloning runs on CosyVoice3 0.5B. Download and select CosyVoice3 in Models → Voice to speak with cloned voices.")
                            .font(.caption)
                            .foregroundStyle(Theme.fitAmber)
                            .padding(Theme.Space.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.fitAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                    }

                    savedProfilesSection
                    createProfileSection
                }
                .padding(Theme.Space.lg)
            }
            .background(Theme.bg)
            .navigationTitle("Voice Cloning")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        recorder.stopRecording()
                        recorder.stopPreview()
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $showAudioImporter,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: false
            ) { result in
                handleImportedAudio(result)
            }
            .onDisappear {
                recorder.stopRecording()
                recorder.stopPreview()
                cleanupImportedStaging()
            }
        }
    }

    @ViewBuilder private var savedProfilesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("SAVED VOICES")
                .font(.caption2.weight(.bold)).tracking(0.6).foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 4)

            if voiceClones.profiles.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No cloned voices yet")
                        .font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary)
                    Text("Record or import a clean 5–15 second speech clip below to clone any voice locally on device.")
                        .font(.caption).foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .studioCard()
            } else {
                VStack(spacing: Theme.Space.sm) {
                    ForEach(voiceClones.profiles) { profile in
                        let isActive = settings.ttsEngineKind == .localMLX && settings.localMLXVoiceID == profile.id
                        let clipURL = voiceClones.audioURL(for: profile)
                        let isPlayingThis = recorder.isPlayingPreview && recorder.playingURL == clipURL

                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            HStack(spacing: Theme.Space.sm) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name)
                                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                                    Text(String(format: "%.1fs reference", profile.durationSeconds))
                                        .font(.caption2).foregroundStyle(Theme.textTertiary)
                                }
                                Spacer()
                                Button {
                                    recorder.togglePreview(url: clipURL)
                                } label: {
                                    Image(systemName: isPlayingThis ? "stop.circle.fill" : "play.circle")
                                        .font(.title3)
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(isPlayingThis ? "Stop preview" : "Play reference clip")

                                if isActive {
                                    Label("Active", systemImage: "checkmark.circle.fill")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Theme.accent)
                                } else {
                                    Button("Use") {
                                        activateClonedVoice(profile.id)
                                    }
                                    .buttonStyle(StudioButtonStyle(.secondary))
                                }

                                Button(role: .destructive) {
                                    if isPlayingThis { recorder.stopPreview() }
                                    voiceClones.delete(id: profile.id)
                                } label: {
                                    Image(systemName: "trash").foregroundStyle(Theme.textSecondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Delete \(profile.name)")
                            }

                            if !profile.referenceTranscript.isEmpty {
                                Text("“\(profile.referenceTranscript)”")
                                    .font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(2)
                            }
                        }
                        .studioCard()
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                                .strokeBorder(isActive ? Theme.accent : .clear, lineWidth: 1.5)
                        )
                    }
                }
            }
        }
    }

    private var createProfileSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("NEW CLONED VOICE")
                .font(.caption2.weight(.bold)).tracking(0.6).foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: Theme.Space.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Voice name").font(.caption).foregroundStyle(Theme.textTertiary)
                    TextField("My Voice", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .font(.subheadline)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Reference script (read aloud or match audio)")
                            .font(.caption).foregroundStyle(Theme.textTertiary)
                        Spacer()
                        HStack(spacing: 6) {
                            ForEach(VoiceSampleRecorder.sampleScripts) { script in
                                Button(script.label) {
                                    draftTranscript = script.text
                                }
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Theme.accent)
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    TextField(
                        "Enter the exact words spoken in the reference clip",
                        text: $draftTranscript,
                        axis: .vertical
                    )
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline)

                    Text("Providing the exact transcript improves voice similarity and pronunciation stability.")
                        .font(.caption2).foregroundStyle(Theme.textTertiary)
                }

                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack(spacing: Theme.Space.sm) {
                        Button {
                            cleanupImportedStaging()
                            if recorder.isRecording {
                                recorder.stopRecording()
                            } else {
                                Task { await recorder.startRecording() }
                            }
                        } label: {
                            Label(
                                recorder.isRecording
                                    ? String(format: "Stop (%.1fs / %.0fs)", recorder.elapsedSeconds, recorder.maxDurationSeconds)
                                    : "Record Sample",
                                systemImage: recorder.isRecording ? "stop.circle.fill" : "mic.circle.fill"
                            )
                        }
                        .buttonStyle(StudioButtonStyle(recorder.isRecording ? .primary : .secondary))

                        Button {
                            if recorder.isRecording { recorder.stopRecording() }
                            showAudioImporter = true
                        } label: {
                            Label("Import Audio", systemImage: "folder")
                        }
                        .buttonStyle(StudioButtonStyle(.secondary))
                    }

                    if let url = activeSourceURL, !recorder.isRecording {
                        HStack(spacing: Theme.Space.sm) {
                            let isPlayingDraft = recorder.isPlayingPreview && recorder.playingURL == url
                            Button {
                                recorder.togglePreview(url: url)
                            } label: {
                                Label(
                                    isPlayingDraft
                                        ? "Stop preview"
                                        : String(format: "Preview clip (%.1fs)", activeSourceDuration),
                                    systemImage: isPlayingDraft ? "stop.circle.fill" : "play.circle"
                                )
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Theme.accent)
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Button("Clear") {
                                recorder.discardRecording()
                                cleanupImportedStaging()
                            }
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 2)
                    }
                }

                if let error = statusError ?? recorder.errorMessage {
                    Text(error).font(.caption).foregroundStyle(Theme.danger)
                }

                Button {
                    saveDraftProfile()
                } label: {
                    Label("Save & Use Voice", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(StudioButtonStyle(.primary))
                .disabled(!canSave)
            }
            .studioCard()
        }
    }

    private func handleImportedAudio(_ result: Result<[URL], Error>) {
        statusError = nil
        recorder.discardRecording()
        cleanupImportedStaging()

        switch result {
        case .success(let urls):
            guard let picked = urls.first else { return }
            let scoped = picked.startAccessingSecurityScopedResource()
            defer { if scoped { picked.stopAccessingSecurityScopedResource() } }

            do {
                let ext = picked.pathExtension.isEmpty ? "wav" : picked.pathExtension.lowercased()
                let staged = FileManager.default.temporaryDirectory
                    .appending(component: "voice-clone-import-\(UUID().uuidString).\(ext)")
                try FileManager.default.copyItem(at: picked, to: staged)
                let duration = try VoiceSampleRecorder.audioDuration(at: staged)
                guard duration >= 1.5, duration <= 30.0 else {
                    try? FileManager.default.removeItem(at: staged)
                    statusError = String(format: "Audio must be 1.5–30s long (selected clip is %.1fs).", duration)
                    return
                }
                importedStagingURL = staged
                importedDuration = duration
                if draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    draftName = picked.deletingPathExtension().lastPathComponent
                }
            } catch {
                statusError = "Could not import audio: \(error.localizedDescription)"
            }
        case .failure(let error):
            statusError = error.localizedDescription
        }
    }

    private func saveDraftProfile() {
        guard let url = activeSourceURL else { return }
        statusError = nil
        do {
            let profile = try voiceClones.addProfile(
                name: draftName,
                sourceAudioURL: url,
                referenceTranscript: draftTranscript,
                durationSeconds: activeSourceDuration
            )
            activateClonedVoice(profile.id)
            draftName = ""
            recorder.discardRecording()
            cleanupImportedStaging()
        } catch {
            statusError = error.localizedDescription
        }
    }

    private func activateClonedVoice(_ profileID: String) {
        if !isCosyVoiceActive, let cosyID = installedCosyVoiceVariantID {
            settings.localMLXModelVariantID = cosyID
        }
        settings.localMLXVoiceID = profileID
        settings.ttsEngineKind = .localMLX
    }

    private func cleanupImportedStaging() {
        if let url = importedStagingURL {
            if recorder.playingURL == url {
                recorder.stopPreview()
            }
            try? FileManager.default.removeItem(at: url)
            importedStagingURL = nil
            importedDuration = 0
        }
    }
}
