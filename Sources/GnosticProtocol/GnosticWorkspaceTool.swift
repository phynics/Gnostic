// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The safe subset of a Workspace tool definition advertised by Gnostic.
public struct GnosticWorkspaceTool: Codable, Sendable, Equatable {
    /// The stable tool identifier.
    public let id: String

    /// The display name of the tool.
    public let name: String

    /// The tool's user-facing description.
    public let toolDescription: String

    /// The tool's parameter schema.
    public let parametersSchema: [String: GnosticJSONValue]

    /// An optional usage example.
    public let usageExample: String?

    /// Whether execution requires user approval.
    public let requiresPermission: Bool

    /// Creates a safe tool projection.
    public init(definition: GnosticWorkspaceToolDefinition) {
        id = definition.id
        name = definition.name
        toolDescription = definition.description
        parametersSchema = definition.parametersSchema
        usageExample = definition.usageExample
        requiresPermission = definition.requiresPermission
    }

    /// Creates a tool projection from already-projected fields.
    ///
    /// The Workspace tool object uses this to rebuild the tool it carries.
    package init(
        id: String,
        name: String,
        toolDescription: String,
        parametersSchema: [String: GnosticJSONValue],
        usageExample: String?,
        requiresPermission: Bool
    ) {
        self.id = id
        self.name = name
        self.toolDescription = toolDescription
        self.parametersSchema = parametersSchema
        self.usageExample = usageExample
        self.requiresPermission = requiresPermission
    }
}
