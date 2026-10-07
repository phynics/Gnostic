// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation

/// A host-local Workspace the runtime advertises and invokes.
///
/// Implementations own their reference and tool projection. The runtime treats
/// the Workspace as an opaque, backend-neutral capability: it never sees the
/// provider-native value behind it.
@MainActor
public protocol LocalWorkspace: Sendable {
    /// The Workspace the runtime advertises.
    var reference: BackendWorkspaceReference { get }
    /// Lists the tools the Workspace currently advertises.
    ///
    /// - Returns: The advertised tools.
    /// - Throws: When the Workspace cannot enumerate them.
    func listTools() async throws -> [BackendWorkspaceTool]
    /// Invokes one advertised tool.
    ///
    /// - Parameters:
    ///   - id: The advertised tool identifier.
    ///   - parameters: The tool arguments, matching its declared schema.
    /// - Returns: The tool result.
    /// - Throws: When the tool is unknown or rejects the call.
    func executeTool(id: String, parameters: [String: ManifestJSONValue]) async throws -> BackendWorkspaceResult
}

/// Optional direct file access for a host-local Workspace.
@MainActor
public protocol LocalWorkspaceFileAccess: Sendable {
    /// Reads one file relative to the Workspace root.
    ///
    /// - Parameter path: The Workspace-relative path.
    /// - Returns: The file contents.
    /// - Throws: When the file cannot be read.
    func readFile(path: String) async throws -> String
    /// Writes one file relative to the Workspace root.
    ///
    /// - Parameters:
    ///   - path: The Workspace-relative path.
    ///   - content: The contents to write.
    /// - Throws: When the file cannot be written.
    func writeFile(path: String, content: String) async throws
    /// Lists the entries of one Workspace-relative directory.
    ///
    /// - Parameter path: The Workspace-relative directory.
    /// - Returns: The entry names.
    /// - Throws: When the directory cannot be listed.
    func listFiles(path: String) async throws -> [String]
    /// Deletes one file relative to the Workspace root.
    ///
    /// - Parameter path: The Workspace-relative path.
    /// - Throws: When the file cannot be deleted.
    func deleteFile(path: String) async throws
}

/// Health of a host-local Workspace.
@MainActor
public protocol LocalWorkspaceHealth: Sendable {
    /// Whether the Workspace's backing storage is reachable.
    var isHealthy: Bool { get }
}

/// Invokes a tool on a network Workspace the host knows only through its
/// catalog descriptor.
@MainActor
public protocol NetworkWorkspaceInvoking: Sendable {
    /// Invokes one tool on one network Workspace.
    ///
    /// - Parameter invocation: The Workspace, tool, and arguments.
    /// - Returns: The tool result.
    /// - Throws: When the transport fails or the tool rejects the call.
    func invoke(_ invocation: BackendWorkspaceInvocation) async throws -> BackendWorkspaceResult
}

/// The workspace tool invocation operation name shared by the serving and
/// consuming sides of the wire contract.
public enum GnosticWorkspaceProtocol {
    /// The single operation used for all workspace tool invocations.
    public static let invocationOperation = "me.atkn.gnostic.workspace.invoke"
}

/// Transport registration for local Workspace tool invocation.
@MainActor
public protocol LocalWorkspaceTransportServing: Sendable {
    /// Registers the unary invocation handler.
    ///
    /// - Parameter communication: The node's communication manager.
    /// - Returns: The registration, which the caller cancels.
    /// - Throws: When registration fails.
    func register(on communication: CommunicationManager) async throws -> CallHandlerRegistration
    /// Registers the tool-catalog query responder.
    ///
    /// - Parameter communication: The node's communication manager.
    /// - Returns: The registration, which the caller cancels.
    func registerQuery(on communication: CommunicationManager) async -> QueryResponderRegistration
}
