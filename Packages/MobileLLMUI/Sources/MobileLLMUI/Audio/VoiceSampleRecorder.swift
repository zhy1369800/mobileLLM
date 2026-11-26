// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation
import Observation

/// Records and previews 3–25 second reference audio clips for zero-shot voice cloning.
@MainActor
@Observable
public final class VoiceSampleRecorder {
    public struct SampleScript: Identifiable, Hashable, Sendable {
        public let id: String
        public let label: String
        public let text: String

        public init(id: String, label: String, text: String) {
            self.id = id
            self.label = label
            self.text = text
        }
    }

    public static let sampleScripts: [SampleScript] = [
        SampleScript(
            id: "zh",
            label: "中文示例",
            text: "今天天气不错，阳光温和，微风轻轻吹过，我很开心能够在这里与你自然流畅地交流。"
        ),
        SampleScript(
            id: "en",
            label: "English Sample",
            text: "Hello there, the weather feels calm and pleasant today, and I am glad to test this natural voice clone with you."
        ),
    ]

    public let maxDurationSeconds: Double = 25.0

    public private(set) var isRecording: Bool = false
    public private(set) var isPlayingPreview: Bool = false
    public private(set) var playingURL: URL?
    public private(set) var elapsedSeconds: Double = 0
    public private(set) var recordedURL: URL?
    public private(set) var recordedDuration: Double = 0
    public private(set) var errorMessage: String?

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private let playerDelegate = PlayerDelegateProxy()

    public init() {
        playerDelegate.owner = self
    }

    deinit {
        timerTask?.cancel()
    }

    public func startRecording() async {
        errorMessage = nil
        stopPreview()

        let granted = await requestMicrophonePermission()
        guard granted else {
            errorMessage = "Microphone permission is required to record a voice sample."
            return
        }

        discardRecording()

        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            errorMessage = "Could not activate microphone audio session: \(error.localizedDescription)"
            return
        }
        #endif

        let outputURL = FileManager.default.temporaryDirectory
            .appending(component: "voice-clone-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 24_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        do {
            let rec = try AVAudioRecorder(url: outputURL, settings: settings)
            rec.prepareToRecord()
            guard rec.record() else {
                errorMessage = "Failed to start audio recording."
                deactivateRecordingSession()
                return
            }
            self.recorder = rec
            self.recordedURL = outputURL
            self.elapsedSeconds = 0
            self.recordedDuration = 0
            self.isRecording = true

            timerTask?.cancel()
            timerTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let start = Date()
                while !Task.isCancelled, self.isRecording {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, self.isRecording else { break }
                    let elapsed = Date().timeIntervalSince(start)
                    self.elapsedSeconds = elapsed
                    if elapsed >= self.maxDurationSeconds {
                        self.stopRecording()
                        break
                    }
                }
            }
        } catch {
            errorMessage = "Could not start recording: \(error.localizedDescription)"
            deactivateRecordingSession()
        }
    }

    public func stopRecording() {
        timerTask?.cancel()
        timerTask = nil
        if let recorder {
            recorder.stop()
        }
        recorder = nil
        isRecording = false
        deactivateRecordingSession()

        if let url = recordedURL {
            recordedDuration = (try? Self.audioDuration(at: url)) ?? elapsedSeconds
        }
    }

    public func togglePreview(url: URL) {
        if isPlayingPreview, playingURL == url {
            stopPreview()
            return
        }
        stopPreview()
        errorMessage = nil

        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            // Best effort.
        }
        #endif

        do {
            let data: Data = try {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try Data(contentsOf: url)
            }()

            let p = try AVAudioPlayer(data: data)
            p.delegate = playerDelegate
            p.prepareToPlay()
            guard p.play() else {
                deactivateRecordingSession()
                errorMessage = "Could not play audio preview."
                return
            }
            player = p
            playingURL = url
            isPlayingPreview = true
        } catch {
            deactivateRecordingSession()
            errorMessage = "Could not open audio file: \(error.localizedDescription)"
        }
    }

    public func stopPreview() {
        let hadPreview = player != nil || isPlayingPreview
        player?.stop()
        player = nil
        playingURL = nil
        isPlayingPreview = false
        if hadPreview {
            deactivateRecordingSession()
        }
    }

    public func discardRecording() {
        if isRecording {
            stopRecording()
        }
        stopPreview()
        if let url = recordedURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordedURL = nil
        recordedDuration = 0
        elapsedSeconds = 0
    }

    public static func audioDuration(at url: URL) throws -> Double {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return 0 }
        return Double(file.length) / rate
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func deactivateRecordingSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    fileprivate func finishPreview() {
        isPlayingPreview = false
        playingURL = nil
        player = nil
        deactivateRecordingSession()
    }

    private final class PlayerDelegateProxy: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
        weak var owner: VoiceSampleRecorder?

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            Task { @MainActor [weak owner] in
                owner?.finishPreview()
            }
        }

        func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
            Task { @MainActor [weak owner] in
                owner?.finishPreview()
            }
        }
    }
}
