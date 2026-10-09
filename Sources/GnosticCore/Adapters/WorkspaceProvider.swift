// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticProtocol

/// The wire payload for Gnostic's generic remote workspace invocation.
public struct WorkspaceInvocation: Codable, Sendable {
    public let protocolMajor: Int
    /// The stable identifier of the advertised workspace.
    public let workspaceID: UUID

    /// The catalog provider identity selected for this invocation.
    public let providerID: String?

    /// The advertised custom tool identifier.
    public let toolID: String

    /// The tool arguments supplied by the caller.
    public let arguments: [String: ManifestJSONValue]

    /// Creates an invocation payload.
    public init(workspaceID: UUID, providerID: String? = nil, toolID: String, arguments: [String: ManifestJSONValue] = [:], protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        self.workspaceID = workspaceID
        self.providerID = providerID
        self.toolID = toolID
        self.arguments = arguments
    }

    private enum CodingKeys: String, CodingKey { case protocolMajor, workspaceID, providerID, toolID, arguments }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        workspaceID = try container.decode(UUID.self, forKey: .workspaceID)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
        toolID = try container.decode(String.self, forKey: .toolID)
        arguments = try container.decode([String: ManifestJSONValue].self, forKey: .arguments)
    }
}
