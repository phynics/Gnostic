// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PKShared
import PositronicKit

/// Converts a safe network descriptor into the runtime reference used by the
/// timeline manager and remote workspace proxy.
public enum WorkspaceReferenceProjection {
    public enum Error: Swift.Error, Sendable, Equatable {
        case invalidURI
    }

    public static func reference(from descriptor: NetworkWorkspaceDescriptor) throws -> WorkspaceReference {
        guard let uri = WorkspaceURI(parsing: descriptor.uri) else {
            throw Error.invalidURI
        }
        return WorkspaceReference(
            id: descriptor.id,
            uri: uri,
            location: .runtime,
            tools: descriptor.tools.map { tool in
                .custom(WorkspaceToolDefinition(
                    id: tool.id,
                    name: tool.name,
                    description: tool.toolDescription,
                    parametersSchema: tool.parametersSchema,
                    usageExample: tool.usageExample,
                    requiresPermission: tool.requiresPermission
                ))
            }
        )
    }
}
