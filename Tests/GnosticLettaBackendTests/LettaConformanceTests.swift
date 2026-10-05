// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticAscendantConformance
import GnosticCore
import GnosticLettaBackend
import GnosticLettaTestSupport
import Testing

/// Runs the shared AscendantBackend conformance suite against the Letta
/// backend with its in-process fixture transport (GNO-PLAT-060, #452).
@Suite("Letta Ascendant conformance", .serialized)
struct LettaConformanceTests {
    @Test("identity and configuration")
    @MainActor
    func identityAndConfiguration() async throws {
        try await lettaConformanceFixture().suite().checkIdentityAndConfiguration()
    }

    @Test("Timeline lifecycle")
    @MainActor
    func timelineLifecycle() async throws {
        try await lettaConformanceFixture().suite().checkTimelineLifecycle()
    }

    @Test("a successful Turn streams and returns text")
    @MainActor
    func successfulTurn() async throws {
        try await lettaConformanceFixture().suite().checkSuccessfulTurnStreamsText()
    }

    @Test("a terminal failure leaves the backend usable")
    @MainActor
    func terminalFailure() async throws {
        try await lettaConformanceFixture().suite().checkTerminalFailureKeepsBackendUsable()
    }

    @Test("backend cancellation interrupts a stalled Turn")
    @MainActor
    func cancellation() async throws {
        try await lettaConformanceFixture().suite().checkBackendCancellationInterruptsStall()
    }

    @Test("Workspace attachments project onto a Timeline")
    @MainActor
    func workspaceAttachment() async throws {
        try await lettaConformanceFixture().suite().checkWorkspaceAttachmentProjects()
    }

    @Test("health, quarantine, reconstruction, and replay")
    @MainActor
    func hostHealthQuarantineAndReplay() async throws {
        try await lettaHostConformanceFixture().suite().checkHealthQuarantineAndReplay()
    }
}

/// The Letta backend does not implement scoped Turn cancellation: recorded in #452.
@MainActor
func lettaConformanceFixture() -> AscendantConformanceFixture {
    let signal = AscendantConformanceTurnSignal()
    let workspace = AscendantConformanceWorkspaceService()
    return AscendantConformanceFixture(
        kind: LettaAscendantBackend.kind,
        surfaces: [.workspaceAttachment, .terminalUpdate],
        workspaceService: workspace,
        awaitTurnStarted: { _ = await signal.waitUntilStarted() },
        makeBackend: { ascendant, timelines in
            let transport = FixtureLettaTransport(scriptForMessage: { message in
                if message.contains(AscendantConformanceMessage.stall) {
                    Task { await signal.markStarted() }
                    return .hang
                }
                if message.contains(AscendantConformanceMessage.terminalFailure) {
                    return .failure("error")
                }
                return .plain(AscendantConformanceReply.make(for: message))
            })
            return try LettaAscendantBackend(
                ascendant: ascendant,
                configuration: conformanceLettaConfiguration(),
                services: .init(workspace: workspace, permission: AscendantConformancePermissionService()),
                timelines: timelines,
                transport: transport
            )
        }
    )
}

/// A host-level Letta fixture. A Letta transport outage is lifecycle-unusable,
/// so breaking the live transport breaks the backend until reconstruction.
@MainActor
func lettaHostConformanceFixture() -> AscendantHostConformanceFixture {
    let transportBox = LettaConformanceTransportBox()
    return AscendantHostConformanceFixture(
        kind: LettaAscendantBackend.kind,
        makeAdapters: {
            var adapters = NodeRuntimeAdapters.default
            adapters.ascendants.registerBackend(
                kind: LettaAscendantBackend.kind,
                settings: LettaAscendantBackend.settingsSchema
            ) { ascendant, _, services, timelines in
                let transport = FixtureLettaTransport()
                transportBox.hold(transport)
                return try LettaAscendantBackend(
                    ascendant: ascendant,
                    configuration: conformanceLettaConfiguration(),
                    services: services,
                    timelines: timelines,
                    transport: transport
                )
            }
            return adapters
        },
        breakLiveBackend: {
            await transportBox.transport?.setSendFailure(.unreachable("conformance offline"))
        }
    )
}

@MainActor
private func conformanceLettaConfiguration() -> AscendantBackendConfiguration {
    AscendantBackendConfiguration(
        kind: LettaAscendantBackend.kind,
        settings: [
            "serverURL": .string("http://127.0.0.1:8283"),
            "model": .string("openai/test-model"),
        ],
        secrets: ["apiKey": .string("conformance")]
    )
}

/// Holds the transport of the most recently constructed Letta backend.
@MainActor
private final class LettaConformanceTransportBox: Sendable {
    private(set) var transport: FixtureLettaTransport?

    func hold(_ transport: FixtureLettaTransport) {
        self.transport = transport
    }
}
