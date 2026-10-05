// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticAscendantConformance
import GnosticCore
import PKContracts
import PositronicKit
import Testing

/// Runs the shared AscendantBackend conformance suite against the bundled
/// Positronic adapter with a scripted language model (GNO-PLAT-060, #452).
@Suite("Positronic Ascendant conformance")
struct PositronicConformanceTests {
    @Test("identity and configuration")
    @MainActor
    func identityAndConfiguration() async throws {
        try await positronicConformanceFixture().suite().checkIdentityAndConfiguration()
    }

    @Test("Timeline lifecycle")
    @MainActor
    func timelineLifecycle() async throws {
        try await positronicConformanceFixture().suite().checkTimelineLifecycle()
    }

    @Test("a successful Turn streams and returns text")
    @MainActor
    func successfulTurn() async throws {
        try await positronicConformanceFixture().suite().checkSuccessfulTurnStreamsText()
    }

    @Test("a terminal failure leaves the backend usable")
    @MainActor
    func terminalFailure() async throws {
        try await positronicConformanceFixture().suite().checkTerminalFailureKeepsBackendUsable()
    }

    @Test("backend cancellation interrupts a stalled Turn")
    @MainActor
    func cancellation() async throws {
        try await positronicConformanceFixture().suite().checkBackendCancellationInterruptsStall()
    }

    @Test("Workspace attachments project onto a Timeline")
    @MainActor
    func workspaceAttachment() async throws {
        try await positronicConformanceFixture().suite().checkWorkspaceAttachmentProjects()
    }

    @Test("health, quarantine, reconstruction, and replay")
    @MainActor
    func hostHealthQuarantineAndReplay() async throws {
        try await positronicHostConformanceFixture().suite().checkHealthQuarantineAndReplay()
    }
}

/// A fixture for the Positronic adapter. The adapter does not implement scoped
/// Turn cancellation, and it does not mark its streaming updates terminal:
/// both are recorded exceptions in #452.
@MainActor
func positronicConformanceFixture() -> AscendantConformanceFixture {
    let signal = AscendantConformanceTurnSignal()
    let workspace = AscendantConformanceWorkspaceService()
    return AscendantConformanceFixture(
        kind: AscendantAdapterRegistry.positronicKind,
        surfaces: [.workspaceAttachment],
        workspaceService: workspace,
        awaitTurnStarted: { _ = await signal.waitUntilStarted() },
        makeBackend: { ascendant, timelines in
            try await PositronicAscendantAdapter(
                ascendant: ascendant,
                backend: ascendant.backend,
                services: .init(workspace: workspace, permission: AscendantConformancePermissionService()),
                timelines: timelines,
                languageModel: PositronicConformanceLanguageModel(signal: signal)
            )
        }
    )
}

/// A host-level fixture for the Positronic adapter. The adapter reports
/// lifecycle-unusable after `shutdown()`, so that breaks the live backend.
@MainActor
func positronicHostConformanceFixture() -> AscendantHostConformanceFixture {
    let box = AscendantConformanceBackendBox()
    return AscendantHostConformanceFixture(
        kind: AscendantAdapterRegistry.positronicKind,
        makeAdapters: {
            var adapters = NodeRuntimeAdapters.default
            adapters.ascendants.registerBackend(
                kind: AscendantAdapterRegistry.positronicKind,
                settings: PositronicAscendantAdapter.settingsSchema
            ) { ascendant, configuration, services, timelines in
                let backend = try await PositronicAscendantAdapter(
                    ascendant: ascendant,
                    backend: configuration,
                    services: services,
                    timelines: timelines,
                    languageModel: PositronicConformanceLanguageModel(signal: AscendantConformanceTurnSignal())
                )
                box.hold(backend)
                return backend
            }
            return adapters
        },
        breakLiveBackend: {
            await box.backend?.shutdown()
        }
    )
}

/// A scripted model that honors the conformance message markers.
private final class PositronicConformanceLanguageModel: LLMStreamClient, @unchecked Sendable {
    private let signal: AscendantConformanceTurnSignal

    init(signal: AscendantConformanceTurnSignal) {
        self.signal = signal
    }

    var isConfigured: Bool {
        get async { true }
    }

    var configuration: LLMConfiguration {
        get async { .init(activeProvider: .openAI, providers: [:]) }
    }

    func generationStream(
        messages: [LLMMessage],
        tools _: [LLMToolDefinition]?,
        toolChoice _: LLMToolChoice?,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?,
        modelTier _: ModelTier,
        responseModalities _: Set<ResponseModality>,
        audioOutput _: AudioOutputOptions?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let prompt = messages.last(where: { $0.role == .user })?.content
            ?? messages.last?.content
            ?? ""

        if prompt.contains(AscendantConformanceMessage.stall) {
            return AsyncThrowingStream { _ in
                Task { await signal.markStarted() }
                // Never yields: the Turn only ends when the backend cancels it.
            }
        }
        if prompt.contains(AscendantConformanceMessage.terminalFailure) {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: PositronicConformanceError.terminal)
            }
        }

        let reply = AscendantConformanceReply.make(for: prompt)
        return AsyncThrowingStream { continuation in
            continuation.yield(LLMStreamChunk(
                id: "conformance",
                model: "conformance",
                choices: [LLMStreamChoice(
                    index: 0,
                    delta: LLMStreamDelta(content: reply),
                    finishReason: "stop"
                )]
            ))
            continuation.finish()
        }
    }
}

/// A terminal model failure the adapter maps to ``AscendantBackendError/terminal(_:)``.
private enum PositronicConformanceError: Error {
    case terminal
}
