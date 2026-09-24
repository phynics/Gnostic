// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
@testable import GnosticCore
import Testing

/// A paginated list page must fit the embedded payload budget together with
/// its `nextOffset`, otherwise a page chosen to fit fails at encoding time.
@Suite("List pagination budget")
struct ListPaginationBudgetTests {
    @Test("timeline.list pages fit the budget with their continuation offset at every size")
    func timelineListPagesFitWithNextOffset() async throws {
        let sizes = (0...GnosticWirePayload.maximumAttachedWorkspaceIDs).flatMap { workspaceCount in
            (1...GnosticWirePayload.maximumLabelBytes).map { (workspaceCount, $0) }
        }
        for (workspaceCount, titleLength) in sizes {
            let statuses = (0..<3).map { _ in
                TimelineStatus(
                    timelineID: UUID(),
                    title: String(repeating: "t", count: titleLength),
                    attachedWorkspaceIDs: (0..<workspaceCount).map { _ in UUID() }
                )
            }
            let provider = TimelineManagementProvider(
                create: { _, _ in throw CancellationError() },
                list: { statuses },
                update: { _ in throw CancellationError() }
            )
            let request = String(decoding: try JSONEncoder().encode(TimelineListRequest()), as: UTF8.self)

            let result = try await provider.handle(operation: TimelineManagementProvider.listOperation, parameters: request)

            guard case let .success(payload, _) = result else {
                Issue.record("\(workspaceCount) workspaces, title length \(titleLength) failed: \(result)")
                return
            }
            let page = try JSONDecoder().decode(TimelineListResult.self, from: Data(payload.utf8))
            #expect(!page.timelines.isEmpty)
            #expect(page.nextOffset == (page.timelines.count < statuses.count ? page.timelines.count : nil))
        }
    }
}
