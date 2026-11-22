// SPDX-License-Identifier: MIT

#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import Foundation
import MobileLLMUI

/// Bridges framework-agnostic `VoiceLiveActivitySnapshot` events from `VoiceChatSession`
/// to iOS `ActivityKit` with 300ms throttling for streaming subtitle updates.
@MainActor
final class VoiceLiveActivityBridge: VoiceLiveActivityProviding {
    private var activeActivityID: String?
    private var lastPublishedState: VoiceChatActivityAttributes.ContentState?
    private var lastUpdateTime: Date = .distantPast
    private var deferredUpdateTask: Task<Void, Never>?
    private var pendingState: VoiceChatActivityAttributes.ContentState?

    private let minimumSubtitleInterval: TimeInterval = 0.30

    /// Cleans up stale Live Activities left behind by an earlier crash or forced termination.
    func cleanupOrphanedActivities() {
        let ids = Activity<VoiceChatActivityAttributes>.activities.map(\.id)
        guard !ids.isEmpty else { return }
        Task {
            await Self.endActivities(ids: ids)
        }
    }

    func start(with snapshot: VoiceLiveActivitySnapshot) {
        deferredUpdateTask?.cancel()
        deferredUpdateTask = nil
        pendingState = nil

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            activeActivityID = nil
            lastPublishedState = nil
            return
        }

        let staleIDs = Activity<VoiceChatActivityAttributes>.activities.map(\.id)
        let state = Self.makeContentState(from: snapshot)
        let attributes = VoiceChatActivityAttributes(sessionID: UUID().uuidString)
        let content = ActivityContent(state: state, staleDate: nil, relevanceScore: 100)

        do {
            let activity = try Activity<VoiceChatActivityAttributes>.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            activeActivityID = activity.id
            lastPublishedState = state
            lastUpdateTime = Date()
            if !staleIDs.isEmpty {
                Task {
                    await Self.endActivities(ids: staleIDs)
                }
            }
        } catch {
            activeActivityID = nil
            lastPublishedState = nil
        }
    }

    func update(with snapshot: VoiceLiveActivitySnapshot) {
        guard let activityID = activeActivityID else { return }
        let state = Self.makeContentState(from: snapshot)
        guard state != lastPublishedState else { return }

        let now = Date()
        let isUrgentChange = lastPublishedState.map { prev in
            prev.phase != state.phase
                || prev.toolName != state.toolName
                || prev.toolRunning != state.toolRunning
                || prev.modelName != state.modelName
        } ?? true

        let elapsed = now.timeIntervalSince(lastUpdateTime)
        if isUrgentChange || elapsed >= minimumSubtitleInterval {
            pushNow(state, to: activityID, at: now)
            return
        }

        pendingState = state
        guard deferredUpdateTask == nil else { return }
        let remaining = max(minimumSubtitleInterval - elapsed, 0.05)
        deferredUpdateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int((remaining * 1000).rounded())))
            guard let self, !Task.isCancelled else { return }
            self.deferredUpdateTask = nil
            guard let targetID = self.activeActivityID, let pending = self.pendingState else { return }
            self.pendingState = nil
            if pending != self.lastPublishedState {
                self.pushNow(pending, to: targetID, at: Date())
            }
        }
    }

    func end() {
        deferredUpdateTask?.cancel()
        deferredUpdateTask = nil
        pendingState = nil
        lastPublishedState = nil
        let currentID = activeActivityID
        activeActivityID = nil

        var ids = Set(Activity<VoiceChatActivityAttributes>.activities.map(\.id))
        if let currentID {
            ids.insert(currentID)
        }
        guard !ids.isEmpty else { return }
        Task {
            await Self.endActivities(ids: Array(ids))
        }
    }

    // MARK: - Helpers

    private func pushNow(_ state: VoiceChatActivityAttributes.ContentState, to activityID: String, at time: Date) {
        deferredUpdateTask?.cancel()
        deferredUpdateTask = nil
        pendingState = nil
        lastPublishedState = state
        lastUpdateTime = time
        Task {
            await Self.updateActivity(id: activityID, state: state)
        }
    }

    private nonisolated static func makeContentState(
        from snapshot: VoiceLiveActivitySnapshot
    ) -> VoiceChatActivityAttributes.ContentState {
        let phase: VoiceChatActivityAttributes.ContentState.Phase
        switch snapshot.phase {
        case .listening: phase = .listening
        case .thinking: phase = .thinking
        case .speaking: phase = .speaking
        }
        return VoiceChatActivityAttributes.ContentState(
            phase: phase,
            subtitle: snapshot.subtitle,
            toolName: snapshot.toolName,
            toolRunning: snapshot.toolRunning,
            modelName: snapshot.modelName
        )
    }

    private nonisolated static func updateActivity(
        id: String,
        state: VoiceChatActivityAttributes.ContentState
    ) async {
        guard let activity = Activity<VoiceChatActivityAttributes>.activities.first(where: { $0.id == id }) else {
            return
        }
        let content = ActivityContent(state: state, staleDate: nil, relevanceScore: 100)
        await activity.update(content)
    }

    private nonisolated static func endActivities(ids: [String]) async {
        let idSet = Set(ids)
        for activity in Activity<VoiceChatActivityAttributes>.activities where idSet.contains(activity.id) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
#endif
