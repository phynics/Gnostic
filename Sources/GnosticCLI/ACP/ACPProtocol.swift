// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PKContracts

/// The small stable ACP v1 surface implemented by `gnostic acp`.
///
/// The wire structs intentionally keep unknown ACP extension fields out of the
/// Gnostic domain model. They are decoded at the adapter boundary and never
/// become Timeline or Workspace state.
public enum ACPProtocol {
    public static let version = 1
    public static let turnIDMetadataKey = "dev.phynics.pi-acp-client/clientTurnID"
}

struct ACPTextContent: Codable, Sendable {
    let type: String
    let text: String
}

struct ACPPromptParameters: Codable, Sendable {
    let sessionID: String
    let prompt: [ACPPromptContent]
    let mcpServers: [AnyCodable]?
    let metadata: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case prompt
        case mcpServers
        case metadata = "_meta"
    }
}

struct ACPPromptContent: Codable, Sendable {
    let type: String
    let text: String?
}

struct ACPSessionParameters: Codable, Sendable {
    let cwd: String
    let mcpServers: [AnyCodable]?
}

struct ACPResumeParameters: Codable, Sendable {
    let sessionID: String
    let cwd: String
    let mcpServers: [AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case cwd
        case mcpServers
    }
}

struct ACPListParameters: Codable, Sendable {
    let cwd: String?
    let cursor: String?
}

struct ACPCloseParameters: Codable, Sendable {
    let sessionID: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
    }
}

struct ACPProfile: Codable, Sendable {
    let id: String
    let name: String
    let command: String
    let args: [String]
    let env: [String: String]
}

struct ACPProfileBundle: Codable, Sendable {
    let version: Int
    let defaultProfile: String?
    let profiles: [ACPProfile]
}

struct ACPSessionRecord: Codable, Sendable, Identifiable {
    let id: String
    let profileFingerprint: String
    let ascendantID: UUID
    let timelineID: UUID
    let providerID: String?
    let cwd: String
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var closedAt: Date?
}

extension ACPPromptParameters {
    var text: String? {
        let parts = prompt.compactMap { part -> String? in
            guard part.type == "text" else { return nil }
            return part.text
        }
        guard parts.count == prompt.count else { return nil }
        let value = parts.joined()
        return value.isEmpty ? nil : value
    }

    var clientTurnID: String? {
        guard let value = metadata?[ACPProtocol.turnIDMetadataKey] else { return nil }
        guard case let .string(id) = value, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return id
    }
}
