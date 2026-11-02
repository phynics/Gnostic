// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// An immutable snapshot of a Workspace tool that a Node returned from a
/// query. A Node never advertises tool objects; it only answers a query for
/// the tools of one Workspace.
///
/// It is a value: a consumer can pass it between actors without
/// synchronization. Read it from ``NetworkCatalogEntry/workspaceToolSnapshot``.
public struct WorkspaceToolSnapshot: Sendable, Equatable {
    /// The protocol major the tool object carries.
    public let protocolMajor: Int

    /// The Workspace that owns the tool.
    public let workspaceID: UUID

    /// The tool's safe description.
    public let tool: GnosticWorkspaceTool

    /// The index of the query page that carried the tool.
    public let page: Int

    /// Whether the parameter schema was too large for one tool object.
    ///
    /// The tool remains invocable. A client can treat the empty schema as opaque.
    public let schemaTruncated: Bool

    /// Creates a Workspace tool snapshot.
    public init(
        protocolMajor: Int = GnosticProtocol.currentMajor,
        workspaceID: UUID,
        tool: GnosticWorkspaceTool,
        page: Int = 0,
        schemaTruncated: Bool = false
    ) {
        self.protocolMajor = protocolMajor
        self.workspaceID = workspaceID
        self.tool = tool
        self.page = page
        self.schemaTruncated = schemaTruncated
    }
}
