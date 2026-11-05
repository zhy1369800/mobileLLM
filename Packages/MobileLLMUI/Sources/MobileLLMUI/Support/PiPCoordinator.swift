// SPDX-License-Identifier: MIT

import SwiftUI
#if os(iOS)
import UIKit
import AVKit
import AVFoundation

/// The display state of the Picture-in-Picture floating window.
public enum PiPDisplayStatus: Equatable, Sendable {
    case idle
    case thinking
    case responding
}

/// SwiftUI View rendered inside the Picture-in-Picture floating window.
public struct PiPFloatingCardView: View {
    public let status: PiPDisplayStatus
    public let text: String

    public init(status: PiPDisplayStatus, text: String) {
        self.status = status
        self.text = text
    }

    private var statusTitle: String {
        switch status {
        case .idle: return "mobileLLM 待命"
        case .thinking: return "正在思考..."
        case .responding: return "AI 回复"
        }
    }

    private var statusColor: Color {
        switch status {
        case .idle: return .blue
        case .thinking: return .orange
        case .responding: return .green
        }
    }

    public var body: some View {
        ZStack {
            Color(red: 0.11, green: 0.11, blue: 0.13)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 8) {
                // Header with status indicator and title
                HStack(alignment: .center, spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(statusTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))

                    Spacer()
                }

                // Scrollable response text content
                ScrollView(.vertical, showsIndicators: true) {
                    Text(text.isEmpty ? "等待提问输入..." : text)
                        .font(.system(size: 12, weight: .regular))
                        .lineSpacing(3)
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }

                // Subtle footer hint
                HStack {
                    Spacer()
                    Text("轻点浮窗呼出左上角✕关闭 · 也可轻扫贴边")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 8, trailing: 12))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }
}

/// Coordinates the Picture-in-Picture floating window lifecycle (spec §PiP).
/// When enabled, iOS presents a floating window on the home screen displaying live AI thoughts and replies.
/// When disabled, this coordinator is completely dormant with zero side-effects.
@MainActor
public final class PiPCoordinator: NSObject, @preconcurrency AVPictureInPictureControllerDelegate {
    public static let shared = PiPCoordinator()

    public private(set) var isSupported: Bool = false
    public private(set) var isPiPActive: Bool = false

    private var pipController: AVPictureInPictureController?
    private var videoCallVC: AVPictureInPictureVideoCallViewController?
    private var hostingVC: UIHostingController<PiPFloatingCardView>?
    private var sourceView: UIView?

    private var currentStatus: PiPDisplayStatus = .idle
    private var currentText: String = ""

    private override init() {
        super.init()
        isSupported = AVPictureInPictureController.isPictureInPictureSupported()
    }

    /// Attaches the source view used for Picture-in-Picture transitions.
    public func setup(with parentView: UIView) {
        guard isSupported else { return }
        guard pipController == nil else { return }

        // Transparent source anchor with valid onscreen geometry (280x180)
        // iOS requires the sourceView to be within the visible bounds of the window
        // for `canStartPictureInPictureAutomaticallyFromInline` to be eligible.
        let containerView = UIView(frame: CGRect(x: 20, y: 100, width: 280, height: 180))
        containerView.backgroundColor = .clear
        containerView.isOpaque = false
        containerView.clipsToBounds = true
        containerView.layer.cornerRadius = 16
        containerView.alpha = 0.05
        containerView.isUserInteractionEnabled = false
        parentView.addSubview(containerView)
        self.sourceView = containerView

        let pipVC = AVPictureInPictureVideoCallViewController()
        pipVC.preferredContentSize = CGSize(width: 280, height: 180)

        let initialCard = PiPFloatingCardView(
            status: currentStatus,
            text: currentText
        )
        let host = UIHostingController(rootView: initialCard)
        host.view.frame = pipVC.view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.backgroundColor = .clear

        pipVC.addChild(host)
        pipVC.view.addSubview(host.view)
        host.didMove(toParent: pipVC)

        self.videoCallVC = pipVC
        self.hostingVC = host

        let source = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: containerView,
            contentViewController: pipVC
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        // Strictly disabled by default; only enabled when user explicitly turns on the setting
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        self.pipController = controller
    }

    /// Configures audio session and enables automatic PiP entry when backgrounding.
    public func setEnabled(_ enabled: Bool) {
        guard isSupported else { return }
        if enabled {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            pipController?.canStartPictureInPictureAutomaticallyFromInline = true
            videoCallVC?.view.isHidden = false
            hostingVC?.view.alpha = 1
        } else {
            stopPiP()
            pipController?.canStartPictureInPictureAutomaticallyFromInline = false
            videoCallVC?.view.isHidden = true
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Updates the text and status rendered inside the floating window.
    public func update(status: PiPDisplayStatus, text: String) {
        guard isPiPActive || (pipController?.canStartPictureInPictureAutomaticallyFromInline == true) else { return }
        self.currentStatus = status
        self.currentText = text
        videoCallVC?.view.isHidden = false
        hostingVC?.view.alpha = 1
        hostingVC?.rootView = PiPFloatingCardView(
            status: status,
            text: text
        )
    }

    /// Starts Picture-in-Picture explicitly if not already active.
    public func startPiP() {
        guard let controller = pipController, controller.canStartPictureInPictureAutomaticallyFromInline, !controller.isPictureInPictureActive else { return }
        videoCallVC?.view.isHidden = false
        hostingVC?.view.alpha = 1
        controller.startPictureInPicture()
    }

    /// Stops Picture-in-Picture if active.
    public func stopPiP() {
        guard let controller = pipController, controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
        videoCallVC?.view.isHidden = true
        videoCallVC?.view.removeFromSuperview()
    }

    // MARK: - AVPictureInPictureControllerDelegate

    public nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            PiPCoordinator.shared.videoCallVC?.view.isHidden = false
            PiPCoordinator.shared.hostingVC?.view.alpha = 1
            PiPCoordinator.shared.isPiPActive = true
        }
    }

    public nonisolated func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            PiPCoordinator.shared.videoCallVC?.view.isHidden = true
            PiPCoordinator.shared.videoCallVC?.view.removeFromSuperview()
        }
    }

    public nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            PiPCoordinator.shared.isPiPActive = false
            PiPCoordinator.shared.videoCallVC?.view.isHidden = true
            PiPCoordinator.shared.videoCallVC?.view.removeFromSuperview()
        }
    }

    public nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in
            PiPCoordinator.shared.isPiPActive = false
            PiPCoordinator.shared.videoCallVC?.view.isHidden = true
            PiPCoordinator.shared.videoCallVC?.view.removeFromSuperview()
        }
    }

    public nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in
            PiPCoordinator.shared.stopPiP()
            PiPCoordinator.shared.videoCallVC?.view.isHidden = true
            PiPCoordinator.shared.videoCallVC?.view.removeFromSuperview()
            completionHandler(true)
        }
    }
}
#else
public enum PiPDisplayStatus: Equatable, Sendable {
    case idle
    case thinking
    case responding
}

@MainActor
public final class PiPCoordinator {
    public static let shared = PiPCoordinator()
    public var isSupported: Bool { false }
    public var isPiPActive: Bool { false }
    public func setEnabled(_ enabled: Bool) {}
    public func update(status: PiPDisplayStatus, text: String) {}
    public func startPiP() {}
    public func stopPiP() {}
}
#endif
