// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore
import PKContracts
import PositronicKit
import struct PositronicKit.Thread

extension Optional {
    func unwrap() throws -> Wrapped {
        guard let self else { throw RunnerError.missingRuntimeComponent }
        return self
    }
}

enum RunnerError: Error {
    case missingRuntimeComponent
    case timelineNotReadvertised
}

final class TimelineReadvertisement: @unchecked Sendable {
    private(set) var latest: Thread?
    func record(_ timeline: Thread) { latest = timeline }
}

func waitForWorkspace(_ catalog: NetworkCatalog, id: UUID) async throws {
    for _ in 0..<50 {
        if case .available = await catalog.workspaceAttachmentStatus(id: id) { return }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw CancellationError()
}

func invoke(_ workspace: AxolotyWorkspace, id: String, arguments: [String: AnyCodable], expected: String) async throws {
    let result = try await workspace.executeTool(id: id, parameters: arguments)
    guard result.success, result.output == expected else { throw RunnerError.timelineNotReadvertised }
    print("generic network call passed: \(id)")
}
