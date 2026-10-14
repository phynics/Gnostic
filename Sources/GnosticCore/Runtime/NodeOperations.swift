// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The inward Node operation seam. The broker transport calls this interface
/// for every Node operation instead of holding one closure per operation.
///
/// `NodeRuntime` is the production adapter. The transport test suite supplies
/// a stub adapter, so the seam is real rather than hypothetical. The seam
/// carries only Gnostic-owned operation inputs and results.
@MainActor
protocol NodeOperations: AnyObject, Sendable {
    /// Runs one Turn against the Ascendant that operates the addressed
    /// Timeline.
    ///
    /// - Returns: The Turn result the backend produced.
    func turn(_ request: AscendantTurnRequest) async throws -> AscendantTurnResult

    /// Cancels one admitted Turn identified by its client Turn identity.
    ///
    /// - Returns: `true` when an admitted Turn was cancelled.
    func cancelTurn(_ request: AscendantTurnCancellationRequest) async -> Bool

    /// Returns the status of one Timeline.
    ///
    /// - Returns: The canonical status projection for the Timeline.
    func timelineStatus(for timelineID: UUID) async throws -> TimelineStatus

    /// Returns the Ascendant selected to operate an addressed Timeline.
    ///
    /// - Returns: The selected Ascendant identity.
    func selectAscendant(requested ascendantID: UUID?) async throws -> UUID

    /// Creates a process-only Timeline in the selected Ascendant.
    ///
    /// - Returns: The status of the created Timeline.
    func createTimeline(title: String, ascendantID: UUID) async throws -> TimelineStatus

    /// Lists every Timeline the Node knows.
    ///
    /// - Returns: The status of every known Timeline.
    func listTimelines() async throws -> [TimelineStatus]

    /// Renames one Timeline.
    ///
    /// - Returns: The status of the renamed Timeline.
    func renameTimeline(_ request: TimelineUpdateRequest) async throws -> TimelineStatus

    /// Lists every Workspace the Node can attach.
    ///
    /// - Returns: The attachable Workspace listings.
    func listWorkspaces() async -> [WorkspaceListing]

    /// Attaches one Workspace to one Timeline.
    ///
    /// - Returns: `true` when the attachment changed durable state.
    func attachWorkspace(_ request: WorkspaceOpsRequest) async throws -> Bool

    /// Detaches one Workspace from one Timeline.
    ///
    /// - Returns: `true` when the detachment changed durable state.
    func detachWorkspace(_ request: WorkspaceOpsRequest) async throws -> Bool

    /// Returns a payload-free live snapshot for the whole Node.
    ///
    /// - Returns: The Node diagnostics snapshot.
    func diagnosticsNode() async throws -> NodeDiagnostics

    /// Returns a payload-free live snapshot for one Ascendant.
    ///
    /// - Returns: The Ascendant diagnostics snapshot.
    func diagnosticsAscendant(_ ascendantID: UUID) async throws -> AscendantDiagnostics

    /// Returns a payload-free live snapshot for one Timeline.
    ///
    /// - Returns: The Timeline diagnostics snapshot.
    func diagnosticsTimeline(_ timelineID: UUID) async throws -> TimelineDiagnostics
}
