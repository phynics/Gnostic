// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticAscendantConformance
import GnosticCore
import GnosticProtocol
import PKContracts
import PositronicKit
import Testing
@testable import GnosticPositronicBackend

/// Runs the shared AscendantBackend conformance suite against the bundled
/// Positronic adapter with a scripted language model (GNO-PLAT-060, #452).
@Suite("Positronic Ascendant conformance")
struct PositronicConformanceTests {
    @Test("identity and configuration")
    @MainActor
    func identityAndConfiguration() async throws {
        try await positronicConformanceFixture().suite().checkIdentityAndConfiguration()
    }

    @Test("capability declaration agrees with conformance, fixture surfaces, and advertisement")
    @MainActor
    func capabilityDeclarationAgrees() async throws {
        try await positronicConformanceFixture().suite().checkCapabilityDeclarationAgrees()
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

    @Test("a model can attach a Workspace to a Timeline created after backend construction")
    @MainActor
    func attachWorkspaceToRuntimeCreatedTimeline() async throws {
        let workspaceID = UUID()
        let runtimeTimelineID = UUID()
        let ascendantID = UUID()
        let defaultTimelineID = UUID()
        let ascendant = NodeManifest.Ascendant(
            id: ascendantID,
            name: "Runtime attachment",
            defaultTimelineID: defaultTimelineID,
            backend: .init(kind: AscendantAdapterRegistry.positronicKind)
        )
        let timelines = [NodeManifest.Timeline(id: defaultTimelineID, title: "Default", operatingAscendantID: ascendantID)]
        let discovery = RuntimeAttachmentDiscovery(workspaceID: workspaceID)
        let recorder = RuntimeAttachmentRecorder()
        let host = BackendWorkspaceAttachmentCapability { workspaceID, timelineID in
            await recorder.record(workspaceID: workspaceID, timelineID: timelineID)
        }
        let services = AscendantBackendServices(
            permission: AscendantConformancePermissionService(),
            optionalCapabilities: [
                BackendWorkspaceDiscoveryCapability(discovery: discovery),
                host,
            ]
        )
        let adapter = try await PositronicAscendantAdapter(
            ascendant: ascendant,
            backend: ascendant.backend,
            services: services,
            timelines: timelines,
            languageModel: RuntimeAttachmentLanguageModel(workspaceID: workspaceID, timelineID: runtimeTimelineID)
        )
        // The Timeline is created after backend construction, like a Timeline
        // created by an ACP/pi session.
        _ = try await adapter.createTimeline(id: runtimeTimelineID, title: "Runtime")

        _ = try await adapter.runTurn(
            AscendantBackendTurnRequest(
                timelineID: runtimeTimelineID,
                message: "attach the workspace",
                clientTurnID: UUID().uuidString
            ),
            updates: AscendantConformanceUpdateSink()
        )

        #expect(await recorder.workspaceID == workspaceID)
        #expect(await recorder.timelineID == runtimeTimelineID)
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

/// Discovery for one available Workspace, so the adapter builds the
/// `attach_workspace` tool without a broker or catalog.
@MainActor
private final class RuntimeAttachmentDiscovery: WorkspaceDiscovery {
    private let workspaceID: UUID
    private let providerID = "runtime-attachment"
    private let uri = "workspace://runtime-attachment"

    init(workspaceID: UUID) {
        self.workspaceID = workspaceID
    }

    func discover(timeout _: Duration) async {}
    func objects() async -> [NetworkCatalogEntry] { [] }
    func queryTools(workspaceID _: UUID, timeout _: Duration) async {}

    func attachmentStatus(id: UUID) async -> WorkspaceAttachmentStatus {
        id == workspaceID ? .available(providerID: providerID, uri: uri) : .unavailable
    }

    func descriptor(workspaceID: UUID, providerID: String) async -> NetworkWorkspaceDescriptor? {
        guard workspaceID == self.workspaceID, providerID == self.providerID else { return nil }
        return NetworkWorkspaceDescriptor(id: workspaceID, uri: uri, isAvailable: true, tools: [])
    }
}

/// Records the host attachment the `attach_workspace` tool delegates to.
private actor RuntimeAttachmentRecorder {
    private(set) var workspaceID: UUID?
    private(set) var timelineID: UUID?

    func record(workspaceID: UUID, timelineID: UUID) {
        self.workspaceID = workspaceID
        self.timelineID = timelineID
    }
}

/// A scripted model that calls `attach_workspace` once, then completes.
private final class RuntimeAttachmentLanguageModel: LLMStreamClient, @unchecked Sendable {
    private let workspaceID: UUID
    private let timelineID: UUID
    private let rounds = RuntimeAttachmentRoundCounter()

    init(workspaceID: UUID, timelineID: UUID) {
        self.workspaceID = workspaceID
        self.timelineID = timelineID
    }

    var isConfigured: Bool { get async { true } }
    var configuration: LLMConfiguration { get async { .init(activeProvider: .openAI, providers: [:]) } }

    func generationStream(
        messages _: [LLMMessage],
        tools _: [LLMToolDefinition]?,
        toolChoice _: LLMToolChoice?,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?,
        modelTier _: ModelTier,
        responseModalities _: Set<ResponseModality>,
        audioOutput _: AudioOutputOptions?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        if await rounds.next() == 1 {
            let arguments = #"{"workspaceId":"\#(workspaceID.uuidString)","timelineId":"\#(timelineID.uuidString)"}"#
            return AsyncThrowingStream { continuation in
                continuation.yield(LLMStreamChunk(
                    id: "runtime-attachment",
                    model: "runtime-attachment",
                    choices: [LLMStreamChoice(
                        index: 0,
                        delta: LLMStreamDelta(
                            role: .assistant,
                            toolCalls: [LLMToolCallDelta(
                                index: 0,
                                id: "call_attach",
                                function: LLMToolCallDeltaFunction(name: "attach_workspace", arguments: arguments)
                            )]
                        ),
                        finishReason: "tool_calls"
                    )]
                ))
                continuation.finish()
            }
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(LLMStreamChunk(
                id: "runtime-attachment-final",
                model: "runtime-attachment",
                choices: [LLMStreamChoice(
                    index: 0,
                    delta: LLMStreamDelta(content: "attached"),
                    finishReason: "stop"
                )]
            ))
            continuation.finish()
        }
    }
}

private actor RuntimeAttachmentRoundCounter {
    private var value = 0
    func next() -> Int {
        value += 1
        return value
    }
}
