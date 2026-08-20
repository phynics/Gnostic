// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

public enum NodeManifestError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedSchemaVersion(Int), invalidBroker, invalidNodeSettings, invalidUUID(UUID), invalidKind(kind: String, objectID: UUID), invalidProfile(UUID), invalidBackend(UUID), invalidAttachment(UUID), duplicateID(UUID), duplicateAttachment(UUID, UUID), missingReference(from: UUID, to: UUID), invalidDefaultTimeline(UUID, UUID), immutableIdentity(UUID)
    public var reasonCode: String { switch self { case .unsupportedSchemaVersion: "unsupportedSchemaVersion"; case .invalidBroker: "invalidBroker"; case .invalidNodeSettings: "invalidNodeSettings"; case .invalidUUID: "invalidUUID"; case .invalidKind: "invalidKind"; case .invalidProfile: "invalidProfile"; case .invalidBackend: "invalidBackend"; case .invalidAttachment: "invalidAttachment"; case .duplicateID: "duplicateID"; case .duplicateAttachment: "duplicateAttachment"; case .missingReference: "missingReference"; case .invalidDefaultTimeline: "invalidDefaultTimeline"; case .immutableIdentity: "immutableIdentity" } }
    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version): "Unsupported manifest schema version \(version)."
        case .invalidBroker: "The manifest broker configuration is invalid."
        case .invalidNodeSettings: "The manifest node approval mode or log level is invalid."
        case let .invalidUUID(id): "Manifest object \(id.uuidString) must be a version 4 RFC 4122 UUID."
        case let .invalidKind(kind, id): "Manifest object \(id.uuidString) has invalid kind '\(kind)'."
        case let .invalidProfile(id): "LLM profile \(id.uuidString) is missing a name or provider."
        case let .invalidBackend(id): "Ascendant \(id.uuidString) has an invalid backend configuration envelope."
        case let .invalidAttachment(id): "Timeline \(id.uuidString) has an invalid Workspace attachment."
        case let .duplicateID(id): "Manifest object ID \(id.uuidString) is not unique."
        case let .duplicateAttachment(timeline, workspace): "Timeline \(timeline.uuidString) attaches Workspace \(workspace.uuidString) more than once."
        case let .missingReference(from, to): "Manifest object \(from.uuidString) references missing object \(to.uuidString)."
        case let .invalidDefaultTimeline(ascendant, timeline): "Ascendant \(ascendant.uuidString)'s default Timeline \(timeline.uuidString) is not operated by that Ascendant."
        case let .immutableIdentity(id): "Manifest object \(id.uuidString) changed its immutable identity or kind."
        }
    }
}
