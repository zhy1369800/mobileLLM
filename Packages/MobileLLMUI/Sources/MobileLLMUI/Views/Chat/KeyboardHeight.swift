// SPDX-License-Identifier: MIT

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Dual-source keyboard tracking for `ChatDetailView`:
// Primary: UIKit's `keyboardLayoutGuide` via a transparent (non-hidden) `TrackerView` constrained strictly
// inside `AnchorView` (no cross-hierarchy window constraints that collide with modal sheet transforms).
// Fallback: `UIResponder` keyboard frame/hide notifications converted into `window` coordinates and gated
// against modal presentations (`isTopPresentedContext()`), so modal sheets, menus, or iOS 26 layout-guide
// stalls can never trap the composer beneath the keyboard.

internal enum KeyboardOverlapMath: Sendable {
    enum KeyboardNotificationState: Equatable, Sendable {
        case unknown
        case visible(CGFloat)
        case hidden
    }

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

    static func resolvedLift(
        guideLift: CGFloat,
        guideActiveForCurrentKeyboard: Bool,
        notificationState: KeyboardNotificationState
    ) -> CGFloat {
        switch notificationState {
        case .unknown:
            return max(0, guideLift)
        case .hidden:
            return 0
        case .visible(let notifLift):
            // Once keyboardLayoutGuide has responded for the current keyboard presentation, trust its
            // live measurement all the way down to 0 (interactive drag-to-dismiss / height shrink).
            // Only fall back to the notification height when the guide stalled without responding.
            if guideActiveForCurrentKeyboard || guideLift > 0.5 {
                return max(0, guideLift)
            }
            return max(0, notifLift)
        }
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

        func apply(lift: CGFloat, animationDuration: Double) {
            let target = max(0, lift)
            guard abs(overlap.wrappedValue - target) > 0.5 else { return }
            if animationDuration > 0.01 {
                Task { @MainActor [weak self] in
                    withAnimation(.easeOut(duration: animationDuration)) {
                        self?.commit(target: target)
                    }
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.commit(target: target)
                }
            }
        }

        private func commit(target: CGFloat) {
            guard abs(overlap.wrappedValue - target) > 0.5 else { return }
            overlap.wrappedValue = target
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(overlap: $overlap)
    }

    func makeUIView(context: Context) -> AnchorView {
        let coordinator = context.coordinator
        return AnchorView { lift, duration in
            coordinator.apply(lift: lift, animationDuration: duration)
        }
    }

    func updateUIView(_ view: AnchorView, context: Context) {
        context.coordinator.overlap = $overlap
        view.ensureTrackerInstalledIfNeeded()
    }

    /// Transparent host view attached to `ChatDetailView`'s background.
    @MainActor
    final class AnchorView: UIView {
        private let onLiftChange: (CGFloat, Double) -> Void
        private var tracker: TrackerView?
        private var guideLift: CGFloat = 0
        private var guideActiveForCurrentKeyboard = false
        private var notificationState: KeyboardOverlapMath.KeyboardNotificationState = .unknown

        init(onLiftChange: @escaping (CGFloat, Double) -> Void) {
            self.onLiftChange = onLiftChange
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isHidden = false
            backgroundColor = .clear
            isOpaque = false

            let nc = NotificationCenter.default
            // Re-install tracker when foregrounded (UIWindow survives Home round-trips while UIKit may rebind its guide).
            nc.addObserver(
                self,
                selector: #selector(sceneDidBecomeActive),
                name: UIApplication.didBecomeActiveNotification,
                object: nil
            )
            nc.addObserver(
                self,
                selector: #selector(handleKeyboardNotification(_:)),
                name: UIResponder.keyboardWillChangeFrameNotification,
                object: nil
            )
            nc.addObserver(
                self,
                selector: #selector(handleKeyboardNotification(_:)),
                name: UIResponder.keyboardDidChangeFrameNotification,
                object: nil
            )
            nc.addObserver(
                self,
                selector: #selector(handleKeyboardNotification(_:)),
                name: UIResponder.keyboardWillHideNotification,
                object: nil
            )
            nc.addObserver(
                self,
                selector: #selector(handleKeyboardNotification(_:)),
                name: UIResponder.keyboardDidHideNotification,
                object: nil
            )
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        deinit { NotificationCenter.default.removeObserver(self) }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                notificationState = .unknown
                guideLift = 0
                guideActiveForCurrentKeyboard = false
                onLiftChange(0, 0)
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

        @objc private func handleKeyboardNotification(_ note: Notification) {
            guard let window else { return }
            let isLocal = (note.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool) ?? true
            guard isLocal else { return }

            let isHideNote = note.name == UIResponder.keyboardWillHideNotification
                || note.name == UIResponder.keyboardDidHideNotification
            let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25

            let lift: CGFloat
            if isHideNote {
                lift = 0
            } else if let endScreenFrame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue {
                let endInWindow = window.convert(endScreenFrame, from: nil)
                lift = KeyboardOverlapMath.netLift(
                    windowBounds: window.bounds,
                    keyboardFrameInWindow: endInWindow,
                    restingBottomInset: window.safeAreaInsets.bottom,
                    isHiding: false
                )
            } else {
                lift = 0
            }

            if lift <= 0.5 {
                notificationState = .hidden
                guideLift = 0
                guideActiveForCurrentKeyboard = false
                onLiftChange(0, duration)
                return
            }

            guard isTopPresentedContext() else { return }
            let wasVisibleWithSameHeight: Bool
            if case .visible(let previousLift) = notificationState, abs(previousLift - lift) <= 0.5 {
                wasVisibleWithSameHeight = true
            } else {
                wasVisibleWithSameHeight = false
            }
            if !wasVisibleWithSameHeight {
                guideLift = 0
                guideActiveForCurrentKeyboard = false
            }
            notificationState = .visible(lift)
            let resolved = KeyboardOverlapMath.resolvedLift(
                guideLift: guideLift,
                guideActiveForCurrentKeyboard: guideActiveForCurrentKeyboard,
                notificationState: notificationState
            )
            onLiftChange(resolved, duration)
        }

        private func handleGuideLift(_ lift: CGFloat) {
            if lift > 0.5 {
                guard isTopPresentedContext() else { return }
                guideActiveForCurrentKeyboard = true
            }
            guideLift = lift
            let resolved = KeyboardOverlapMath.resolvedLift(
                guideLift: guideLift,
                guideActiveForCurrentKeyboard: guideActiveForCurrentKeyboard,
                notificationState: notificationState
            )
            onLiftChange(resolved, 0)
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
