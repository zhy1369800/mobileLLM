// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation
import LLMCore

/// Stable failures raised before a local model crosses its generation boundary.
public enum LocalModelAdapterError: Error, Equatable, Sendable {
    case invalidRegistration(String)
    case duplicateSelection(AgentModelSelection)
    case selectionNotRegistered(AgentModelSelection)
    case modelNotResident(AgentModelSelection)
    case generationAlreadyActive
    case residencyTransitionInProgress
    case unloadWhileGenerating
    case artifactUnavailable(ArtifactID)
    case artifactIntegrityMismatch(ArtifactID)
    case artifactLimitExceeded
}

/// Exact metadata binding an Agent Harness selection to one `LLMCore` model artifact.
///
/// The selection is derived from the catalog model and variant identities. It is never inferred at
/// generation time, and no nearest-model or online fallback exists.
public struct LocalModelRegistration: Hashable, Sendable {
    public let selection: AgentModelSelection
    public let model: LLMModel
    public let variant: LLMVariant
    public let weightsDirectory: URL
    public let capabilities: AgentModelCapabilities
    public let toolDialect: ToolDialect

    /// Builds a registration for curated Bonsai/Gemma/Apple entries or an adopted GGUF entry.
    public init(
        providerID: AgentModelProviderID,
        capabilityVersion: SemanticVersion,
        model: LLMModel,
        variant: LLMVariant,
        weightsDirectory: URL,
        maximumOutputTokens: UInt64? = nil
    ) throws {
        guard model.variants.contains(variant),
              variant.backend != .awqUnsupported,
              model.architecture.nativeContext > 0,
              weightsDirectory.isFileURL
        else { throw LocalModelAdapterError.invalidRegistration(model.id) }

        let contextLimit = UInt64(model.architecture.nativeContext)
        let outputLimit = maximumOutputTokens ?? min(contextLimit, 8_192)
        guard outputLimit > 0, outputLimit <= contextLimit else {
            throw LocalModelAdapterError.invalidRegistration(model.id)
        }

        let selection = AgentModelSelection(
            providerID: providerID,
            modelID: try Self.boundedModelID(model.id),
            variantID: try Self.boundedVariantID(variant.id),
            capabilityVersion: capabilityVersion
        )
        var features: [AgentModelCapability] = [.textToolDialect, .multipleToolCalls]
        if model.architecture.thinkingCapable && model.architecture.reasoningStyle.canThink {
            features.append(.reasoning)
        }
        if variant.supportsVisionInput { features.append(.vision) }

        self.selection = selection
        self.model = model
        self.variant = variant
        self.weightsDirectory = weightsDirectory.standardizedFileURL
        capabilities = try AgentModelCapabilities(
            maximumContextTokens: contextLimit,
            maximumOutputTokens: outputLimit,
            features: AgentModelCapabilitySet(features),
            toolCallingMode: .textDialect,
            cancellationGranularity: .token,
            resourceConstraints: ModelResourceConstraints(
                maximumConcurrentAttempts: 1,
                requiresResidentModel: !variant.isSystemProvided,
                requiresDrainBeforeSwitch: true
            ),
            reportsTokenUsage: true,
            reportsCost: false
        )
        toolDialect = ToolDialect(model.architecture.promptTemplate)
    }

    /// Returns a contract-valid model identifier, bounding overlong (>256 UTF-8 byte) Explore IDs with a
    /// deterministic SHA-256 suffix while preserving all normal identifiers byte-for-byte.
    public static func boundedModelID(_ rawValue: String) throws -> AgentModelID {
        try AgentModelID(boundedNamedIdentifier(rawValue, domain: "mobilellm.local-model-id.v1"))
    }

    /// Returns a contract-valid variant identifier, bounding overlong (>256 UTF-8 byte) `sourceArtifactV2`
    /// identifiers with a deterministic SHA-256 suffix while preserving all normal identifiers byte-for-byte.
    public static func boundedVariantID(_ rawValue: String) throws -> AgentModelVariantID {
        try AgentModelVariantID(boundedNamedIdentifier(rawValue, domain: "mobilellm.local-variant-id.v1"))
    }

    private static func boundedNamedIdentifier(_ rawValue: String, domain: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rawValue }
        if trimmed.utf8.count <= 256,
           trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        {
            return trimmed
        }
        let cleanedScalars = trimmed.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        var prefix = ""
        for scalar in cleanedScalars {
            let next = String(scalar)
            if prefix.utf8.count + next.utf8.count > 180 { break }
            prefix += next
        }
        prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = StableDigest.fingerprint(
            domain: domain,
            components: [Data(rawValue.utf8)]
        ).rawValue
        return prefix.isEmpty ? digest : "\(prefix).\(digest)"
    }

    /// Builds every registrable (model, variant) pair across a model catalog, skipping variants whose
    /// backend this runtime cannot serve (AWQ), whose persisted community metadata is malformed, or whose
    /// derived selection/provider identity collides with an earlier entry. Assembly must not fail as a
    /// whole because one explore-adopted record in `adopted-models.json` is invalid or duplicated.
    public static func registrations(
        for models: [LLMModel],
        capabilityVersion: SemanticVersion,
        providerID: (LLMModel, LLMVariant) throws -> AgentModelProviderID,
        weightsDirectory: (LLMVariant) -> URL
    ) throws -> [LocalModelRegistration] {
        var result: [LocalModelRegistration] = []
        var seenSelections: Set<AgentModelSelection> = []
        var seenProviderIDs: Set<AgentModelProviderID> = []
        for model in models {
            for variant in model.variants where variant.backend != .awqUnsupported {
                guard let resolvedProviderID = try? providerID(model, variant),
                      let registration = try? LocalModelRegistration(
                          providerID: resolvedProviderID,
                          capabilityVersion: capabilityVersion,
                          model: model,
                          variant: variant,
                          weightsDirectory: weightsDirectory(variant)
                      ),
                      seenSelections.insert(registration.selection).inserted,
                      seenProviderIDs.insert(registration.selection.providerID).inserted
                else {
                    continue
                }
                result.append(registration)
            }
        }
        return result
    }
}

/// Owns exactly one `LLMEngine` and at most one resident selection.
///
/// The runtime's resource arbiter owns policy. This actor supplies the narrow lifecycle driver and
/// a generation lane shared with `LocalModelProvider`, preventing generation against stale residency.
public actor LLMCoreModelResidencyDriver: ModelResidencyDriver {
    private struct ActiveGeneration: Sendable {
        let id: UUID
        let selection: AgentModelSelection
        let cancel: @Sendable () -> Void
        let awaitCompletion: @Sendable () async -> Void
    }

    private let engine: any LLMEngine
    private var registrations: [AgentModelSelection: LocalModelRegistration]
    public nonisolated let registeredSelections: [AgentModelSelection]
    private var residentSelection: AgentModelSelection?
    private var activeGeneration: ActiveGeneration?
    private var lifecycleTransition = false

    public init(
        engine: any LLMEngine,
        registrations: [LocalModelRegistration]
    ) throws {
        var indexed: [AgentModelSelection: LocalModelRegistration] = [:]
        for registration in registrations {
            guard indexed.updateValue(registration, forKey: registration.selection) == nil else {
                throw LocalModelAdapterError.duplicateSelection(registration.selection)
            }
        }
        guard !indexed.isEmpty else {
            throw LocalModelAdapterError.invalidRegistration("empty local model registry")
        }
        self.engine = engine
        self.registrations = indexed
        registeredSelections = indexed.keys.sorted()
    }

    /// Returns false for the same immutable registration; rejects identity reuse with new metadata.
    @discardableResult
    public func register(_ registration: LocalModelRegistration) throws -> Bool {
        if let existing = registrations[registration.selection] {
            guard existing == registration else { throw LocalModelAdapterError.duplicateSelection(registration.selection) }
            return false
        }
        registrations[registration.selection] = registration
        return true
    }

    public func registration(
        for selection: AgentModelSelection
    ) throws -> LocalModelRegistration {
        guard let registration = registrations[selection] else {
            throw LocalModelAdapterError.selectionNotRegistered(selection)
        }
        return registration
    }

    public func load(selection: AgentModelSelection) async throws {
        let registration = try registration(for: selection)
        guard !lifecycleTransition else {
            throw LocalModelAdapterError.residencyTransitionInProgress
        }
        guard activeGeneration == nil else {
            throw LocalModelAdapterError.generationAlreadyActive
        }
        if residentSelection == selection { return }

        lifecycleTransition = true
        defer { lifecycleTransition = false }
        if residentSelection != nil {
            residentSelection = nil
            await engine.unload()
        }
        do {
            try await engine.load(
                model: registration.model,
                variant: registration.variant,
                weightsDir: registration.weightsDirectory,
                progress: { _ in }
            )
            residentSelection = selection
        } catch {
            await engine.unload()
            residentSelection = nil
            throw error
        }
    }

    public func cancelAndDrain(selection: AgentModelSelection) async throws {
        guard !lifecycleTransition else {
            throw LocalModelAdapterError.residencyTransitionInProgress
        }
        guard let active = activeGeneration, active.selection == selection else { return }
        active.cancel()
        await active.awaitCompletion()
        if activeGeneration?.id == active.id { activeGeneration = nil }
    }

    public func unload(selection: AgentModelSelection) async throws {
        guard !lifecycleTransition else {
            throw LocalModelAdapterError.residencyTransitionInProgress
        }
        guard residentSelection == selection else { return }
        guard activeGeneration == nil else {
            throw LocalModelAdapterError.unloadWhileGenerating
        }

        lifecycleTransition = true
        residentSelection = nil
        defer { lifecycleTransition = false }
        await engine.unload()
    }

    func runGeneration(
        selection: AgentModelSelection,
        operation: @escaping @Sendable (any LLMEngine) async throws -> AgentModelBoundaryCompletion
    ) async throws -> AgentModelBoundaryCompletion {
        guard !lifecycleTransition else {
            throw LocalModelAdapterError.residencyTransitionInProgress
        }
        guard residentSelection == selection else {
            throw LocalModelAdapterError.modelNotResident(selection)
        }
        guard activeGeneration == nil else {
            throw LocalModelAdapterError.generationAlreadyActive
        }

        let id = UUID()
        let task = Task { try await operation(engine) }
        activeGeneration = ActiveGeneration(
            id: id,
            selection: selection,
            cancel: { task.cancel() },
            awaitCompletion: { _ = await task.result }
        )
        do {
            let completion = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            if activeGeneration?.id == id { activeGeneration = nil }
            return completion
        } catch {
            if activeGeneration?.id == id { activeGeneration = nil }
            throw error
        }
    }

    /// Test/diagnostic projection; it never changes residency.
    public var currentResidentSelection: AgentModelSelection? { residentSelection }

    private var pendingToolCallResponses: [AgentRunID: [String]] = [:]

    public func appendPendingToolCallResponse(_ response: String, for runID: AgentRunID) {
        pendingToolCallResponses[runID, default: []].append(response)
    }

    public func pendingToolCallResponses(for runID: AgentRunID) -> [String] {
        pendingToolCallResponses[runID] ?? []
    }

    public func clearPendingToolCallResponses(for runID: AgentRunID) {
        pendingToolCallResponses.removeValue(forKey: runID)
    }
}
