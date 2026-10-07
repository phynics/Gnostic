// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticProtocol

/// A local echo Workspace implementation.
///
/// Every configured echo Workspace uses the same multiplexed provider route
/// while retaining its own stable ID. It is the deterministic Workspace the
/// kernel installs when a manifest declares an `echo` Workspace with no native
/// provider.
public struct EchoWorkspace: LocalWorkspace, LocalWorkspaceFileAccess, LocalWorkspaceHealth, Sendable {
    /// The single tool an echo Workspace advertises.
    nonisolated public static let toolID = "workspace_echo"

    /// The tool definitions an echo Workspace advertises.
    nonisolated public static let toolDefinitions: [BackendWorkspaceTool] = [BackendWorkspaceTool(
        id: toolID,
        name: "Workspace echo",
        description: "Echoes a value from the workspace.",
        parametersSchema: .object([
            "type": .string("object"),
            "properties": .object(["value": .object(["type": .string("string")])]),
            "required": .array([.string("value")]),
            "additionalProperties": .bool(false),
        ])
    )]

    /// The Workspace the runtime advertises.
    public let reference: BackendWorkspaceReference

    /// The Gnostic-owned Workspace identifier.
    public var id: UUID { reference.id }

    /// Creates an echo Workspace over one reference.
    public init(reference: BackendWorkspaceReference) {
        self.reference = reference
    }
    /// Echo owns its tool projection rather than trusting the reference it
    /// was constructed with.
    public func listTools() async throws -> [BackendWorkspaceTool] { Self.toolDefinitions }

    /// Echoes the `value` argument.
    public func executeTool(id: String, parameters: [String: ManifestJSONValue]) async throws -> BackendWorkspaceResult {
        guard id == Self.toolID else { throw WorkspaceServiceError.toolExecutionNotSupported }
        guard case let .string(value)? = parameters["value"] else {
            throw WorkspaceServiceError.toolExecutionNotSupported
        }
        return BackendWorkspaceResult(message: value)
    }

    /// Echo exposes no direct file access.
    public func readFile(path _: String) async throws -> String { throw WorkspaceServiceError.toolExecutionNotSupported }
    /// Echo exposes no direct file access.
    public func writeFile(path _: String, content _: String) async throws { throw WorkspaceServiceError.toolExecutionNotSupported }
    /// Echo exposes no direct file access.
    public func listFiles(path _: String) async throws -> [String] { [] }
    /// Echo exposes no direct file access.
    public func deleteFile(path _: String) async throws { throw WorkspaceServiceError.toolExecutionNotSupported }

    /// Echo is always healthy.
    public var isHealthy: Bool { true }
}
