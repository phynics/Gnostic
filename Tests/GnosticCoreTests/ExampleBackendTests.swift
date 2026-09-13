// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

// The worked example for Documentation/Extending/ascendant-backends.md.
//
// It lives in the test target so the guide cannot describe an API that no
// longer compiles. Keep the guide and this file in step: the guide quotes
// this type by name.

/// A minimal Ascendant backend that echoes the prompt back.
///
/// It implements the mandatory contract and nothing else: no Workspace
/// consumption, no permission mediation, no optional capabilities.
@MainActor
final class EchoAscendantBackend: AscendantBackend {
    let identity: AscendantBackendIdentity
    private var timelines: [AscendantBackendTimeline]
    private var cancelled = false

    init(ascendant: NodeManifest.Ascendant, timelines: [NodeManifest.Timeline]) {
        let now = Date()
        identity = AscendantBackendIdentity(
            id: ascendant.id,
            name: ascendant.name,
            description: ascendant.description,
            privateTimelineID: ascendant.defaultTimelineID,
            primaryWorkspaceID: nil,
            lastActiveAt: now,
            createdAt: now,
            updatedAt: now,
            // Advertise only what this backend genuinely supports.
            capabilities: AscendantBackendCapabilities(
                interoperability: [AscendantInteroperabilityCapability.textTurn.rawValue],
                backendKind: "example-echo"
            )
        )
        self.timelines = timelines.map {
            AscendantBackendTimeline(
                id: $0.id, title: $0.title, attachedWorkspaceIDs: [],
                ascendantID: ascendant.id, isArchived: false, isPrivate: false,
                createdAt: now, updatedAt: now
            )
        }
    }

    /// Semantic checks the host cannot make. The envelope shape is already
    /// validated by `AscendantBackendConfigurationValidator`.
    func validateConfiguration() throws {}

    func operatedTimelines() async throws -> [AscendantBackendTimeline] { timelines }

    func createTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        let now = Date()
        let timeline = AscendantBackendTimeline(
            id: id, title: title, attachedWorkspaceIDs: [], ascendantID: identity.id,
            isArchived: false, isPrivate: false, createdAt: now, updatedAt: now
        )
        timelines.append(timeline)
        return timeline
    }

    func removeTimeline(id: UUID) async { timelines.removeAll { $0.id == id } }

    func renameTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        guard let index = timelines.firstIndex(where: { $0.id == id }) else {
            throw AscendantBackendError.timelineNotFound(id)
        }
        let current = timelines[index]
        let renamed = AscendantBackendTimeline(
            id: current.id, title: title, attachedWorkspaceIDs: current.attachedWorkspaceIDs,
            ascendantID: current.ascendantID, isArchived: current.isArchived,
            isPrivate: current.isPrivate, createdAt: current.createdAt, updatedAt: Date()
        )
        timelines[index] = renamed
        return renamed
    }

    /// Streams incremental output to `updates` and returns the final text.
    ///
    /// Both are required: a client watching the live stream sees the sink, and
    /// a caller that only awaits the result reads the return value.
    func runTurn(
        _ request: AscendantBackendTurnRequest,
        updates: any AscendantBackendUpdateSink
    ) async throws -> String {
        guard timelines.contains(where: { $0.id == request.timelineID }) else {
            throw AscendantBackendError.timelineNotFound(request.timelineID)
        }
        cancelled = false

        let reply = "echo: \(request.message)"
        try await updates.append(
            AscendantBackendUpdate(kind: AscendantTurnUpdateKind.assistantText.rawValue, text: reply)
        )
        if cancelled { throw AscendantBackendError.cancelled }
        try await updates.append(
            AscendantBackendUpdate(kind: AscendantTurnUpdateKind.completion.rawValue, terminal: true)
        )
        return reply
    }

    func cancel() async { cancelled = true }

    func shutdown() async {}
}

@Suite("Extension guide worked example")
struct ExampleBackendTests {
    @Test("the guide's example backend satisfies the mandatory contract")
    @MainActor
    func exampleBackendRunsATurn() async throws {
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000901")!
        let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000902")!
        let ascendant = NodeManifest.Ascendant(
            id: ascendantID, name: "Example", defaultTimelineID: timelineID,
            backend: .init(kind: "example-echo")
        )
        let backend = EchoAscendantBackend(
            ascendant: ascendant,
            timelines: [.init(id: timelineID, title: "Default", operatingAscendantID: ascendantID)]
        )

        try backend.validateConfiguration()
        #expect(try await backend.operatedTimelines().count == 1)

        let sink = RecordingUpdateSink()
        let result = try await backend.runTurn(
            AscendantBackendTurnRequest(timelineID: timelineID, message: "hello"),
            updates: sink
        )

        #expect(result == "echo: hello")
        let kinds = await sink.kinds
        #expect(kinds == ["assistant_text", "completion"])
        #expect(await sink.terminalCount == 1)
    }

    @Test("the example backend registers through the supported seam")
    @MainActor
    func exampleBackendIsRegisterable() {
        var registry = AscendantAdapterRegistry()
        registry.registerBackend(kind: "example-echo") { ascendant, _, _, timelines in
            EchoAscendantBackend(ascendant: ascendant, timelines: timelines)
        }
        #expect(registry.registeredKinds.contains("example-echo"))
    }

    @Test("an unknown Timeline is rejected rather than silently served")
    @MainActor
    func unknownTimelineIsRejected() async throws {
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000903")!
        let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000904")!
        let backend = EchoAscendantBackend(
            ascendant: .init(id: ascendantID, name: "Example", defaultTimelineID: timelineID, backend: .init(kind: "example-echo")),
            timelines: [.init(id: timelineID, title: "Default", operatingAscendantID: ascendantID)]
        )

        await #expect(throws: AscendantBackendError.self) {
            _ = try await backend.runTurn(
                AscendantBackendTurnRequest(timelineID: UUID(), message: "hello"),
                updates: RecordingUpdateSink()
            )
        }
    }
}

/// Collects backend updates so a test can assert what a client would observe.
private actor RecordingUpdateSink: AscendantBackendUpdateSink {
    private(set) var kinds: [String] = []
    private(set) var terminalCount = 0

    func append(_ update: AscendantBackendUpdate) async throws {
        kinds.append(update.kind)
        if update.terminal { terminalCount += 1 }
    }
}
