// SPDX-License-Identifier: MIT

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Pure `keyboardLayoutGuide` tracking for `ChatDetailView`:
// UIKit keeps a transparent (non-hidden) `TrackerView` pinned inside `AnchorView` between
// `keyboardLayoutGuide.topAnchor` and `AnchorView.bottomAnchor` (no cross-hierarchy window
// constraints that collide with modal sheet transforms). Its measured height in window coordinates
// minus `window.safeAreaInsets.bottom` gives the exact live overlap frame-by-frame across keyboard
// presentation, interactive dismissal, and height changes without fighting notification animations.

internal enum KeyboardOverlapMath: Sendable {
    static func netLift(
        windowBounds: CGRect,
        keyboardFrameInWindow: CGRect,
        restingBottomInset: CGFloat,
        isHiding: Bool
    ) -> CGFloat {
        guard !isHiding else { return 0 }
        let intersection = windowBounds.intersection(keyboardFrameInWindow)
        guard !intersection.isNull, intersection.height >= 1 else { return 0 }
        let rawOverlap = max(0, windowBounds.maxY - intersection.minY)
        return max(0, rawOverlap - max(0, restingBottomInset))
    }
}

#if os(iOS)
/// SwiftUI leaf that reports the EXTRA bottom lift the keyboard demands (0 when hidden, keyboard height
/// minus the home-indicator inset when up) into a binding. Subtraction uses UIKit's `window.safeAreaInsets.bottom`
/// because SwiftUI's own `safeAreaInsets` absorbs the keyboard into `.bottom` even while avoidance is disabled.
struct KeyboardGuideReader: UIViewRepresentable {
    @Binding var overlap: CGFloat

    @MainActor
    final class Coordinator {
        var overlap: Binding<CGFloat>

        init(overlap: Binding<CGFloat>) {
            self.overlap = overlap
        }

        func apply(lift: CGFloat) {
            let target = max(0, lift)
            guard abs(overlap.wrappedValue - target) > 0.5 else { return }
            Task { @MainActor [weak self] in
                guard let self, abs(self.overlap.wrappedValue - target) > 0.5 else { return }
                self.overlap.wrappedValue = target
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(overlap: $overlap)
    }

    func makeUIView(context: Context) -> AnchorView {
        let coordinator = context.coordinator
        return AnchorView { lift in
            coordinator.apply(lift: lift)
        }
    }

    func updateUIView(_ view: AnchorView, context: Context) {
        context.coordinator.overlap = $overlap
        view.ensureTrackerInstalledIfNeeded()
    }

    /// Transparent host view attached to `ChatDetailView`'s background.
    @MainActor
    final class AnchorView: UIView {
        private let onHeight: (CGFloat) -> Void
        private var tracker: TrackerView?

        init(onHeight: @escaping (CGFloat) -> Void) {
            self.onHeight = onHeight
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isHidden = false
            backgroundColor = .clear
            isOpaque = false

            // Re-install tracker when foregrounded (UIWindow survives Home round-trips while UIKit may rebind its guide).
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(sceneDidBecomeActive),
                name: UIApplication.didBecomeActiveNotification,
                object: nil
            )
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        deinit { NotificationCenter.default.removeObserver(self) }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                onHeight(0)
            }
            installTracker()
        }

        func ensureTrackerInstalledIfNeeded() {
            if tracker == nil || tracker?.superview !== self {
                installTracker()
            }
        }

        @objc private func sceneDidBecomeActive() {
            installTracker()
            setNeedsLayout()
            layoutIfNeeded()
        }

        private func handleGuideLift(_ lift: CGFloat) {
            if lift > 0.5 {
                guard isTopPresentedContext() else { return }
            }
            onHeight(lift)
        }

        private func installTracker() {
            tracker?.removeFromSuperview()
            tracker = nil
            guard window != nil else { return }

            let t = TrackerView { [weak self] lift in
                self?.handleGuideLift(lift)
            }
            t.isUserInteractionEnabled = false
            t.isHidden = false
            t.backgroundColor = .clear
            t.isOpaque = false
            t.translatesAutoresizingMaskIntoConstraints = false
            addSubview(t)
            let bottomConstraint = t.bottomAnchor.constraint(equalTo: bottomAnchor)
            bottomConstraint.priority = .defaultHigh
            NSLayoutConstraint.activate([
                t.leadingAnchor.constraint(equalTo: leadingAnchor),
                t.trailingAnchor.constraint(equalTo: trailingAnchor),
                t.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
                bottomConstraint,
            ])
            tracker = t
        }

        private func owningViewController() -> UIViewController? {
            var responder: UIResponder? = self
            while let current = responder {
                if let vc = current as? UIViewController {
                    return vc
                }
                responder = current.next
            }
            return nil
        }

        private func isTopPresentedContext() -> Bool {
            if let vc = owningViewController() {
                var cursor: UIViewController? = vc
                while let current = cursor {
                    if let presented = current.presentedViewController, !presented.isBeingDismissed {
                        return false
                    }
                    cursor = current.parent
                }
                return true
            }
            if let presented = window?.rootViewController?.presentedViewController, !presented.isBeingDismissed {
                return false
            }
            return true
        }
    }

    /// Pinned `keyboardLayoutGuide.top` -> `AnchorView.bottom`; laid-out rect converted to window coordinates.
    @MainActor
    final class TrackerView: UIView {
        private let onGuideLift: (CGFloat) -> Void

        init(onGuideLift: @escaping (CGFloat) -> Void) {
            self.onGuideLift = onGuideLift
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let window, bounds.width > 0 else { return }
            let frameInWindow = convert(bounds, to: window)
            let lift = KeyboardOverlapMath.netLift(
                windowBounds: window.bounds,
                keyboardFrameInWindow: frameInWindow,
                restingBottomInset: window.safeAreaInsets.bottom,
                isHiding: false
            )
            onGuideLift(lift)
        }
    }
}
#endif
