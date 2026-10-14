// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

/// One backend's remote Timeline calls, recorded for assertions.
@MainActor
private final class RemoteTimelineRecorder {
    private(set) var ensured: [(id: UUID, title: String)] = []
    private(set) var renamed: [(id: UUID, title: String)] = []
    private(set) var deleted: [UUID] = []
    var ensureError: (any Error)?

    func operations() -> AscendantTimelineRemoteOperations {
        .init(
            ensure: { [weak self] id, title in
                guard let self else { return }
                if let error = ensureError { throw error }
                ensured.append((id, title))
            },
            rename: { [weak self] id, title in self?.renamed.append((id, title)) },
            delete: { [weak self] id in self?.deleted.append(id) }
        )
    }
}

@Suite("Ascendant Timeline registry")
struct AscendantTimelineRegistryTests {
    private func makeTimeline(_ id: UUID, _ title: String, attachments: [UUID] = []) -> NodeManifest.Timeline {
        NodeManifest.Timeline(
            id: id,
            title: title,
            operatingAscendantID: UUID(),
            attachments: attachments.map { .local($0) }
        )
    }

    @Test("configured Timelines keep insertion order and project their attachments")
    @MainActor
    func configuredOrderAndProjection() {
        let ascendantID = UUID()
        let privateID = UUID()
        let secondID = UUID()
        let workspaceID = UUID()
        let recorder = RemoteTimelineRecorder()
        let registry = AscendantTimelineRegistry(
            ascendantID: ascendantID,
            privateTimelineID: privateID,
            configured: [
                makeTimeline(privateID, "Private"),
                makeTimeline(secondID, "Second", attachments: [workspaceID]),
            ],
            remote: recorder.operations()
        )

        #expect(registry.operatedTimelines().map(\.id) == [privateID, secondID])
        #expect(registry.projection(id: privateID)?.isPrivate == true)
        #expect(registry.projection(id: secondID)?.isPrivate == false)
        #expect(registry.attachedWorkspaceIDs(for: secondID) == [workspaceID])
    }

    @Test("create is idempotent, preserves the stored projection, and ensures the remote resource")
    @MainActor
    func createIsIdempotent() async throws {
        let privateID = UUID()
        let recorder = RemoteTimelineRecorder()
        let registry = AscendantTimelineRegistry(
            ascendantID: UUID(),
            privateTimelineID: privateID,
            configured: [],
            remote: recorder.operations()
        )
        let id = UUID()

        let first = try await registry.create(id: id, title: "Created")
        let second = try await registry.create(id: id, title: "Ignored")

        #expect(first.title == "Created")
        #expect(second.title == "Created")
        #expect(registry.operatedTimelines().map(\.id) == [id])
        #expect(recorder.ensured.map(\.id) == [id, id])
        #expect(recorder.ensured.map(\.title) == ["Created", "Created"])
    }

    @Test("a failed remote ensure rolls back a newly inserted Timeline")
    @MainActor
    func createRollsBackOnRemoteFailure() async {
        let recorder = RemoteTimelineRecorder()
        recorder.ensureError = AscendantBackendError.lifecycleUnusable(
            .init(code: "remoteDown", message: "remote unavailable")
        )
        let registry = AscendantTimelineRegistry(
            ascendantID: UUID(),
            privateTimelineID: UUID(),
            configured: [],
            remote: recorder.operations()
        )

        await #expect(throws: AscendantBackendError.self) {
            _ = try await registry.create(id: UUID(), title: "Created")
        }
        #expect(registry.operatedTimelines().isEmpty)
    }

    @Test("rename guards an unknown Timeline and remove is a no-op")
    @MainActor
    func renameGuardAndRemoveNoop() async throws {
        let id = UUID()
        let recorder = RemoteTimelineRecorder()
        let registry = AscendantTimelineRegistry(
            ascendantID: UUID(),
            privateTimelineID: UUID(),
            configured: [makeTimeline(id, "Known")],
            remote: recorder.operations()
        )
        let unknown = UUID()

        await #expect(throws: AscendantBackendError.timelineNotFound(unknown)) {
            _ = try await registry.rename(id: unknown, title: "Nope")
        }
        await registry.remove(id: unknown)
        #expect(recorder.deleted.isEmpty)

        let renamed = try await registry.rename(id: id, title: "Renamed")
        #expect(renamed.title == "Renamed")
        #expect(registry.operatedTimelines().first?.title == "Renamed")

        await registry.remove(id: id)
        #expect(recorder.deleted == [id])
        #expect(registry.operatedTimelines().isEmpty)
    }

    @Test("Workspace attachment is projected and detach is idempotent")
    @MainActor
    func workspaceAttachmentProjection() throws {
        let id = UUID()
        let workspaceID = UUID()
        let recorder = RemoteTimelineRecorder()
        let registry = AscendantTimelineRegistry(
            ascendantID: UUID(),
            privateTimelineID: UUID(),
            configured: [makeTimeline(id, "Known")],
            remote: recorder.operations()
        )

        try registry.attachWorkspace(workspaceID, to: id)
        #expect(registry.projection(id: id)?.attachedWorkspaceIDs == [workspaceID])
        try registry.attachWorkspace(workspaceID, to: id)
        #expect(registry.projection(id: id)?.attachedWorkspaceIDs == [workspaceID])

        registry.detachWorkspace(workspaceID, from: id)
        registry.detachWorkspace(workspaceID, from: id)
        #expect(registry.projection(id: id)?.attachedWorkspaceIDs == [])

        let missing = UUID()
        #expect(throws: AscendantBackendError.timelineNotFound(missing)) {
            try registry.attachWorkspace(workspaceID, to: missing)
        }
    }
}
