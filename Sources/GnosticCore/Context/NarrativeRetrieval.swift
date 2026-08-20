// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A Sendable retrieval query for long-horizon narrative context.
///
/// Carries the current user text and the exact Ascendant/Timeline/Workspace/task/
/// file/tool identifiers so retrieval can rank by identifier match, ranked
/// first, without any embedding or LLM.
public struct NarrativeRetrievalQuery: Sendable, Equatable {
    /// The current user text.
    public let currentUserText: String
    /// The current Ascendant identifier.
    public let ascendantID: UUID?
    /// The current timeline identifiers.
    public let timelineIDs: [UUID]
    /// The current attached workspace identifiers.
    public let workspaceIDs: [UUID]
    /// The current task identifiers.
    public let taskIDs: [String]
    /// The current file paths.
    public let filePaths: [String]
    /// The current tool identifiers.
    public let toolIDs: [String]
    /// The maximum number of entries to return.
    public let limit: Int

    /// Creates a retrieval query.
    public init(
        currentUserText: String,
        ascendantID: UUID? = nil,
        timelineIDs: [UUID] = [],
        workspaceIDs: [UUID] = [],
        taskIDs: [String] = [],
        filePaths: [String] = [],
        toolIDs: [String] = [],
        limit: Int
    ) {
        self.currentUserText = currentUserText
        self.ascendantID = ascendantID
        self.timelineIDs = timelineIDs
        self.workspaceIDs = workspaceIDs
        self.taskIDs = taskIDs
        self.filePaths = filePaths
        self.toolIDs = toolIDs
        self.limit = limit
    }
}
