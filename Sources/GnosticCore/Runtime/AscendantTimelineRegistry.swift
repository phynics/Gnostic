// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticProtocol

/// The remote Timeline operations a backend supplies to the shared registry.
///
/// A backend implements only the operations that touch remote or
/// backend-private state. Ordering, idempotent create, the rename guard,
/// removal no-op, and the Gnostic projection live in
/// ``AscendantTimelineRegistry``.
@MainActor
public struct AscendantTimelineRemoteOperations: Sendable {
    /// Ensures the remote resource for one Timeline exists. Called for both a
    /// new and an already-known Timeline, so the implementation must be
    /// idempotent.
    public typealias Ensure = @MainActor @Sendable (_ id: UUID, _ title: String) async throws -> Void
    /// Renames the remote resource for one Timeline.
    public typealias Rename = @MainActor @Sendable (_ id: UUID, _ title: String) async throws -> Void
    /// Removes the remote resource for one Timeline. Called only for a
    /// Timeline the registry knows, and never concurrently with itself.
    public typealias Delete = @MainActor @Sendable (_ id: UUID) async -> Void

    /// Ensures the remote resource exists.
    public let ensure: Ensure
    /// Renames the remote resource.
    public let rename: Rename
    /// Removes the remote resource.
    public let delete: Delete

    /// Creates the remote operation set.
    public init(
        ensure: @escaping Ensure,
        rename: @escaping Rename,
        delete: @escaping Delete
    ) {
        self.ensure = ensure
        self.rename = rename
        self.delete = delete
    }
}

/// Gnostic-owned Timeline bookkeeping shared by Ascendant backends.
///
/// The registry owns the ordered Timeline table: idempotent create, the
/// rename-not-found guard, the removal no-op, insertion order, attachment
/// projection, and the ``AscendantBackendTimeline`` projection itself. A
/// backend supplies only the remote operations it alone can perform. This is
/// what keeps a backend from rebuilding the same table.
@MainActor
public final class AscendantTimelineRegistry {
    private let ascendantID: UUID
    private let privateTimelineID: UUID
    private let remote: AscendantTimelineRemoteOperations
    private var projections: [UUID: AscendantBackendTimeline]
    private var order: [UUID]

    /// Creates a registry seeded from the configured Timelines.
    ///
    /// Every configured Timeline starts attached to the Workspaces the
    /// manifest lists, private only when it is the Ascendant's private
    /// Timeline, and stamped with the same creation time.
    ///
    /// - Parameters:
    ///   - ascendantID: The operating Ascendant's Gnostic identifier.
    ///   - privateTimelineID: The Ascendant's private Timeline identifier.
    ///   - configured: The Timelines assigned to the Ascendant in the manifest.
    ///   - remote: The backend-owned remote operations.
    public init(
        ascendantID: UUID,
        privateTimelineID: UUID,
        configured: [NodeManifest.Timeline],
        remote: AscendantTimelineRemoteOperations
    ) {
        self.ascendantID = ascendantID
        self.privateTimelineID = privateTimelineID
        self.remote = remote
        let now = Date()
        var projections: [UUID: AscendantBackendTimeline] = [:]
        for timeline in configured {
            projections[timeline.id] = AscendantBackendTimeline(
                id: timeline.id,
                title: timeline.title,
                attachedWorkspaceIDs: timeline.attachments.map(\.workspaceID),
                ascendantID: ascendantID,
                isArchived: false,
                isPrivate: timeline.id == privateTimelineID,
                createdAt: now,
                updatedAt: now
            )
        }
        self.projections = projections
        order = configured.map(\.id)
    }

    /// The known Timelines in insertion order.
    public func operatedTimelines() -> [AscendantBackendTimeline] {
        order.compactMap { projections[$0] }
    }

    /// The projection for one Timeline, or `nil` when it is unknown.
    public func projection(id: UUID) -> AscendantBackendTimeline? { projections[id] }

    /// Whether the registry knows one Timeline.
    public func contains(id: UUID) -> Bool { projections[id] != nil }

    /// Stamps one Timeline's projection as recently active.
    ///
    /// - Parameter id: The Timeline that just served a Turn.
    public func touch(id: UUID) {
        guard let current = projections[id] else { return }
        projections[id] = Self.replacing(
            current,
            title: current.title,
            attachedWorkspaceIDs: current.attachedWorkspaceIDs
        )
    }

    /// The stored title for one Timeline.
    public func title(for id: UUID) -> String? { projections[id]?.title }

    /// The attached Workspace identifiers for one Timeline.
    public func attachedWorkspaceIDs(for id: UUID) -> [UUID] {
        projections[id]?.attachedWorkspaceIDs ?? []
    }

    /// Creates a Timeline, or returns the existing projection when its id is
    /// already known.
    ///
    /// Create is idempotent: a second call for the same id preserves the stored
    /// projection and only ensures the remote resource. A failed remote ensure
    /// rolls back a Timeline this call inserted.
    ///
    /// - Parameters:
    ///   - id: The Gnostic-owned identifier.
    ///   - title: The Timeline title.
    /// - Returns: The created or existing projection.
    /// - Throws: The remote ensure error.
    @discardableResult
    public func create(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        let inserted = projections[id] == nil
        if inserted {
            let now = Date()
            projections[id] = AscendantBackendTimeline(
                id: id,
                title: title,
                attachedWorkspaceIDs: [],
                ascendantID: ascendantID,
                isArchived: false,
                isPrivate: id == privateTimelineID,
                createdAt: now,
                updatedAt: now
            )
            order.append(id)
        }
        do {
            try await remote.ensure(id, projections[id]?.title ?? title)
        } catch {
            if inserted {
                projections.removeValue(forKey: id)
                order.removeAll { $0 == id }
            }
            throw error
        }
        return projections[id]!
    }

    /// Removes a Timeline. Removing an unknown Timeline is not an error.
    ///
    /// - Parameter id: The Timeline to remove.
    public func remove(id: UUID) async {
        guard projections[id] != nil else { return }
        await remote.delete(id)
        projections.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }

    /// Renames a known Timeline.
    ///
    /// - Parameters:
    ///   - id: The Timeline to rename.
    ///   - title: The new title.
    /// - Returns: The updated projection.
    /// - Throws: ``AscendantBackendError/timelineNotFound(_:)`` when the
    ///   Timeline is not known.
    @discardableResult
    public func rename(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        guard let current = projections[id] else {
            throw AscendantBackendError.timelineNotFound(id)
        }
        try await remote.rename(id, title)
        let updated = Self.replacing(current, title: title, attachedWorkspaceIDs: current.attachedWorkspaceIDs)
        projections[id] = updated
        return updated
    }

    /// Attaches a Workspace to one Timeline.
    ///
    /// - Parameters:
    ///   - workspaceID: The Workspace to attach.
    ///   - timelineID: The Timeline receiving it.
    /// - Throws: ``AscendantBackendError/timelineNotFound(_:)`` when the
    ///   Timeline is not known.
    public func attachWorkspace(_ workspaceID: UUID, to timelineID: UUID) throws {
        guard let current = projections[timelineID] else {
            throw AscendantBackendError.timelineNotFound(timelineID)
        }
        guard !current.attachedWorkspaceIDs.contains(workspaceID) else { return }
        projections[timelineID] = Self.replacing(
            current,
            title: current.title,
            attachedWorkspaceIDs: current.attachedWorkspaceIDs + [workspaceID]
        )
    }

    /// Detaches a Workspace from one Timeline. An unknown Timeline or an
    /// unattached Workspace is not an error.
    ///
    /// - Parameters:
    ///   - workspaceID: The Workspace to detach.
    ///   - timelineID: The Timeline losing it.
    public func detachWorkspace(_ workspaceID: UUID, from timelineID: UUID) {
        guard let current = projections[timelineID] else { return }
        guard current.attachedWorkspaceIDs.contains(workspaceID) else { return }
        projections[timelineID] = Self.replacing(
            current,
            title: current.title,
            attachedWorkspaceIDs: current.attachedWorkspaceIDs.filter { $0 != workspaceID }
        )
    }

    private static func replacing(
        _ current: AscendantBackendTimeline,
        title: String,
        attachedWorkspaceIDs: [UUID]
    ) -> AscendantBackendTimeline {
        AscendantBackendTimeline(
            id: current.id,
            title: title,
            attachedWorkspaceIDs: attachedWorkspaceIDs,
            ascendantID: current.ascendantID,
            isArchived: current.isArchived,
            isPrivate: current.isPrivate,
            createdAt: current.createdAt,
            updatedAt: Date()
        )
    }
}
