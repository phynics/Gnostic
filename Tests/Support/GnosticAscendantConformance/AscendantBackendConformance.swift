// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore

/// One reusable suite asserting the mandatory ``AscendantBackend`` contract.
///
/// The suite is backend-neutral: a test target supplies an
/// ``AscendantConformanceFixture`` for Positronic, Letta, or ACP, and the same
/// checks run. Each check group reports every divergence it found.
@MainActor
public struct AscendantBackendConformanceSuite: Sendable {
    /// The backend kind and constructions under test.
    public let fixture: AscendantConformanceFixture

    public init(fixture: AscendantConformanceFixture) {
        self.fixture = fixture
    }

    private struct Setup {
        let ascendant: NodeManifest.Ascendant
        let timelines: [NodeManifest.Timeline]
        let defaultTimelineID: UUID
    }

    private func makeSetup() async throws -> (Setup, any AscendantBackend) {
        let ascendantID = UUID()
        let defaultTimelineID = UUID()
        let secondTimelineID = UUID()
        let ascendant = NodeManifest.Ascendant(
            id: ascendantID,
            name: "Conformance \(fixture.kind)",
            defaultTimelineID: defaultTimelineID,
            backend: .init(kind: fixture.kind)
        )
        let timelines = [
            NodeManifest.Timeline(id: defaultTimelineID, title: "Default", operatingAscendantID: ascendantID),
            NodeManifest.Timeline(id: secondTimelineID, title: "Secondary", operatingAscendantID: ascendantID),
        ]
        let backend = try await fixture.makeBackend(ascendant, timelines)
        return (Setup(ascendant: ascendant, timelines: timelines, defaultTimelineID: defaultTimelineID), backend)
    }

    /// Asserts the identity projection and that a valid envelope validates.
    public func checkIdentityAndConfiguration() async throws {
        var checks = AscendantConformanceChecks(kind: fixture.kind)
        let (setup, backend) = try await makeSetup()

        checks.require(
            backend.identity.id == setup.ascendant.id,
            "identity.id \(backend.identity.id) does not match the configured Ascendant \(setup.ascendant.id)"
        )
        checks.require(
            backend.identity.privateTimelineID == setup.defaultTimelineID,
            "identity.privateTimelineID is not the configured default Timeline"
        )
        checks.require(backend.identity.name == setup.ascendant.name, "identity.name does not match the configured name")
        do {
            try backend.validateConfiguration()
        } catch {
            checks.require(false, "validateConfiguration() threw \(error) for a valid fixture")
        }

        await backend.shutdown()
        try checks.finish()
    }

    /// Asserts the Timeline lifecycle: enumerate, create, rename, and remove.
    public func checkTimelineLifecycle() async throws {
        var checks = AscendantConformanceChecks(kind: fixture.kind)
        let (setup, backend) = try await makeSetup()

        let initial = try await backend.operatedTimelines()
        checks.require(
            Set(initial.map(\.id)) == Set(setup.timelines.map(\.id)),
            "operatedTimelines() returned \(initial.map(\.id)) instead of the configured \(setup.timelines.map(\.id))"
        )

        let createdID = UUID()
        let created = try await backend.createTimeline(id: createdID, title: "Created")
        checks.require(created.id == createdID, "createTimeline returned id \(created.id) instead of \(createdID)")
        checks.require(created.title == "Created", "createTimeline returned title \(created.title)")
        checks.require(
            try await backend.operatedTimelines().contains { $0.id == createdID },
            "a created Timeline is missing from operatedTimelines()"
        )

        _ = try await backend.createTimeline(id: createdID, title: "Created")
        checks.require(
            try await backend.operatedTimelines().filter { $0.id == createdID }.count == 1,
            "createTimeline is not idempotent for the same id"
        )

        let renamed = try await backend.renameTimeline(id: createdID, title: "Renamed")
        checks.require(renamed.title == "Renamed", "renameTimeline returned title \(renamed.title)")
        checks.require(
            try await backend.operatedTimelines().first { $0.id == createdID }?.title == "Renamed",
            "renameTimeline did not project the new title"
        )

        let unknownID = UUID()
        do {
            _ = try await backend.renameTimeline(id: unknownID, title: "Unknown")
            checks.require(false, "renameTimeline of an unknown Timeline did not throw")
        } catch let error as AscendantBackendError {
            checks.require(error == .timelineNotFound(unknownID), "renameTimeline of an unknown Timeline threw \(error)")
        } catch {
            checks.require(false, "renameTimeline of an unknown Timeline threw \(error)")
        }

        await backend.removeTimeline(id: createdID)
        checks.require(
            try await backend.operatedTimelines().allSatisfy { $0.id != createdID },
            "removeTimeline left the Timeline in operatedTimelines()"
        )
        await backend.removeTimeline(id: UUID())

        await backend.shutdown()
        try checks.finish()
    }

    /// Asserts a Turn succeeds, streams its text, and returns the final text.
    public func checkSuccessfulTurnStreamsText() async throws {
        var checks = AscendantConformanceChecks(kind: fixture.kind)
        let (setup, backend) = try await makeSetup()

        let message = "conformance success"
        let expected = fixture.expectedReply(message)
        let sink = AscendantConformanceUpdateSink()
        let text = try await backend.runTurn(
            .init(timelineID: setup.defaultTimelineID, message: message, clientTurnID: "conformance-success"),
            updates: sink
        )
        checks.require(text == expected, "runTurn returned \(text) instead of \(expected)")
        let streamed = await sink.combinedText
        checks.require(streamed.contains(expected), "the update sink streamed \(streamed), which omits \(expected)")
        if fixture.surfaces.contains(.terminalUpdate) {
            checks.require(await sink.hasTerminal, "the final update was not marked terminal")
        }

        await backend.shutdown()
        try checks.finish()
    }

    /// Asserts a terminal failure is reported as such and leaves the backend usable.
    public func checkTerminalFailureKeepsBackendUsable() async throws {
        var checks = AscendantConformanceChecks(kind: fixture.kind)
        let (setup, backend) = try await makeSetup()

        do {
            _ = try await backend.runTurn(
                .init(
                    timelineID: setup.defaultTimelineID,
                    message: AscendantConformanceMessage.message(for: .terminalFailure),
                    clientTurnID: "conformance-terminal"
                ),
                updates: AscendantConformanceUpdateSink()
            )
            checks.require(false, "a terminal-failure Turn returned successfully")
        } catch let error as AscendantBackendError {
            if case .terminal = error {
                // Expected.
            } else {
                checks.require(false, "a terminal-failure Turn threw \(error) instead of .terminal")
            }
        } catch {
            checks.require(false, "a terminal-failure Turn threw \(error) instead of .terminal")
        }

        let message = "conformance after failure"
        let expected = fixture.expectedReply(message)
        do {
            let text = try await backend.runTurn(
                .init(timelineID: setup.defaultTimelineID, message: message, clientTurnID: "conformance-usable"),
                updates: AscendantConformanceUpdateSink()
            )
            checks.require(text == expected, "a Turn after a terminal failure returned \(text) instead of \(expected)")
        } catch {
            checks.require(false, "a Turn after a terminal failure threw \(error)")
        }

        await backend.shutdown()
        try checks.finish()
    }

    /// Asserts backend-wide cancellation interrupts a stalled Turn in bounded time.
    public func checkBackendCancellationInterruptsStall() async throws {
        var checks = AscendantConformanceChecks(kind: fixture.kind)
        let (setup, backend) = try await makeSetup()

        let task = Task { @MainActor in
            try await backend.runTurn(
                .init(
                    timelineID: setup.defaultTimelineID,
                    message: AscendantConformanceMessage.message(for: .stall),
                    clientTurnID: "conformance-stall"
                ),
                updates: AscendantConformanceUpdateSink()
            )
        }
        await fixture.awaitTurnStarted()

        let clock = ContinuousClock()
        let start = clock.now
        await backend.cancel()
        let outcome = await task.result
        let elapsed = clock.now - start

        switch outcome {
        case .success:
            checks.require(false, "a cancelled stalled Turn returned successfully")
        case let .failure(error as AscendantBackendError):
            checks.require(error == .cancelled, "cancelling a stalled Turn threw \(error) instead of .cancelled")
        case let .failure(error):
            checks.require(false, "cancelling a stalled Turn threw \(error) instead of .cancelled")
        }
        checks.require(elapsed <= fixture.cancellationBound, "cancellation settled after \(elapsed), above \(fixture.cancellationBound)")

        await backend.shutdown()
        try checks.finish()
    }

    /// Asserts scoped cancellation interrupts one Timeline's stalled Turn.
    ///
    /// Runs only for a kind that declares ``AscendantConformanceSurfaces/scopedCancellation``.
    public func checkScopedCancellationInterruptsStall() async throws {
        guard fixture.surfaces.contains(.scopedCancellation) else { return }
        var checks = AscendantConformanceChecks(kind: fixture.kind)
        let (setup, backend) = try await makeSetup()

        guard let cancellable = backend.optionalCapability(.turnCancellation, as: (any AscendantBackendTurnCancellation).self) else {
            checks.require(false, "the kind declares scoped cancellation but does not provide AscendantBackendTurnCancellation through its declaration")
            try checks.finish()
            return
        }

        let clientTurnID = "conformance-scoped-stall"
        let task = Task { @MainActor in
            try await backend.runTurn(
                .init(
                    timelineID: setup.defaultTimelineID,
                    message: AscendantConformanceMessage.message(for: .stall),
                    clientTurnID: clientTurnID
                ),
                updates: AscendantConformanceUpdateSink()
            )
        }
        await fixture.awaitTurnStarted()

        let clock = ContinuousClock()
        let start = clock.now
        await cancellable.cancelTurn(timelineID: setup.defaultTimelineID, clientTurnID: clientTurnID)
        let outcome = await task.result
        let elapsed = clock.now - start

        switch outcome {
        case .success:
            checks.require(false, "a scoped-cancelled stalled Turn returned successfully")
        case let .failure(error as AscendantBackendError):
            checks.require(error == .cancelled, "scoped cancellation threw \(error) instead of .cancelled")
        case let .failure(error):
            checks.require(false, "scoped cancellation threw \(error) instead of .cancelled")
        }
        checks.require(elapsed <= fixture.cancellationBound, "scoped cancellation settled after \(elapsed), above \(fixture.cancellationBound)")

        await backend.shutdown()
        try checks.finish()
    }

    /// Asserts that a backend's capability declaration, its conformances, its
    /// fixture surfaces, and its advertised interoperability agree.
    ///
    /// A declared surface must be implemented and an implemented surface must
    /// be declared. A declared Workspace must also be advertised. The reverse
    /// advertisement direction is not asserted here: a kind that advertises a
    /// capability it does not declare is recorded as an exception in the
    /// kind's conformance tests, not silently accepted.
    public func checkCapabilityDeclarationAgrees() async throws {
        var checks = AscendantConformanceChecks(kind: fixture.kind)
        let (_, backend) = try await makeSetup()
        let declared = backend.capabilities

        let workspaceConforms = (backend as? any AscendantBackendWorkspaceCapability) != nil
        checks.require(
            declared.contains(.workspace) == workspaceConforms,
            "declaration .workspace is \(declared.contains(.workspace)) but the backend conformance is \(workspaceConforms)"
        )
        checks.require(
            declared.contains(.workspace) == fixture.surfaces.contains(.workspaceAttachment),
            "declaration .workspace is \(declared.contains(.workspace)) but the fixture surfaces are \(fixture.surfaces)"
        )

        let cancellationConforms = (backend as? any AscendantBackendTurnCancellation) != nil
        checks.require(
            declared.contains(.turnCancellation) == cancellationConforms,
            "declaration .turnCancellation is \(declared.contains(.turnCancellation)) but the backend conformance is \(cancellationConforms)"
        )
        checks.require(
            declared.contains(.turnCancellation) == fixture.surfaces.contains(.scopedCancellation),
            "declaration .turnCancellation is \(declared.contains(.turnCancellation)) but the fixture surfaces are \(fixture.surfaces)"
        )

        let filesAvailable = fixture.workspaceService?.optionalFileService != nil
        checks.require(
            declared.contains(.workspaceFiles) == filesAvailable,
            "declaration .workspaceFiles is \(declared.contains(.workspaceFiles)) but the host Workspace service offers files: \(filesAvailable)"
        )

        if declared.contains(.workspace) {
            let advertised = backend.identity.capabilities.interoperability
            checks.require(
                advertised.contains(AscendantInteroperabilityCapability.workspaceAttachment.rawValue),
                "declares .workspace but does not advertise workspaceAttachment"
            )
        }

        await backend.shutdown()
        try checks.finish()
    }

    /// Asserts a Workspace attachment is projected onto the Timeline.
    ///
    /// Runs only for a kind that declares ``AscendantConformanceSurfaces/workspaceAttachment``.
    public func checkWorkspaceAttachmentProjects() async throws {
        guard let workspace = fixture.workspaceService else { return }
        var checks = AscendantConformanceChecks(kind: fixture.kind)
        let (setup, backend) = try await makeSetup()

        guard let capability = backend.optionalCapability(.workspace, as: (any AscendantBackendWorkspaceCapability).self) else {
            checks.require(false, "the kind declares Workspace attachment but does not provide AscendantBackendWorkspaceCapability through its declaration")
            try checks.finish()
            return
        }

        do {
            try await capability.attachWorkspace(workspace.reference, to: setup.defaultTimelineID)
        } catch {
            checks.require(false, "attachWorkspace threw \(error)")
        }
        let attached = try await backend.operatedTimelines()
            .first { $0.id == setup.defaultTimelineID }?.attachedWorkspaceIDs ?? []
        checks.require(
            attached.contains(workspace.reference.id),
            "attachWorkspace did not project the Workspace; attachedWorkspaceIDs are \(attached)"
        )

        do {
            try await capability.detachWorkspace(workspace.reference.id, from: setup.defaultTimelineID)
        } catch {
            checks.require(false, "detachWorkspace threw \(error)")
        }
        let detached = try await backend.operatedTimelines()
            .first { $0.id == setup.defaultTimelineID }?.attachedWorkspaceIDs ?? []
        checks.require(
            !detached.contains(workspace.reference.id),
            "detachWorkspace did not remove the Workspace projection; attachedWorkspaceIDs are \(detached)"
        )

        await backend.shutdown()
        try checks.finish()
    }
}
