// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticProtocol

/// Kernel-owned failures raised by the neutral Workspace service.
public enum WorkspaceServiceError: Error, Sendable, Equatable, LocalizedError {
    /// The Workspace transport could not be reached.
    case connectionFailed
    /// The Workspace is not known to this runtime.
    case workspaceNotFound
    /// The Workspace does not support tool execution.
    case toolExecutionNotSupported
    /// The Workspace does not support direct file access.
    case fileAccessNotSupported

    /// A client-safe description of the failure.
    public var errorDescription: String? {
        switch self {
        case .connectionFailed: "The workspace transport could not be reached."
        case .workspaceNotFound: "The workspace is not known to this runtime."
        case .toolExecutionNotSupported: "The workspace does not support tool execution."
        case .fileAccessNotSupported: "The workspace does not support direct file access."
        }
    }
}

/// Mutating companion to ``AscendantBackendWorkspaceService`` used by the
/// kernel when it resolves a network Workspace lazily and must refresh the
/// backend's cached view.
@MainActor
public protocol WorkspaceReferenceUpdating: AscendantBackendWorkspaceService {
    /// Replaces the backend's cached view of one Workspace.
    ///
    /// - Parameter reference: The refreshed Workspace reference.
    func update(reference: BackendWorkspaceReference)
}

/// Direct file access to attached Workspaces.
///
/// Distinct from ``AscendantBackendWorkspaceService``, which is the tool-call
/// surface every Workspace-consuming backend gets. This protocol is optional
/// and kept out of the mandatory backend contract because a remote capability
/// Workspace need not be a filesystem at all.
@MainActor
public protocol AscendantBackendWorkspaceFileService: Sendable {
    /// Reads one file relative to the Workspace root.
    ///
    /// - Parameters:
    ///   - workspaceID: The Gnostic-owned Workspace identifier.
    ///   - path: The Workspace-relative path.
    /// - Returns: The file contents.
    /// - Throws: When the file cannot be read.
    func readFile(workspaceID: UUID, path: String) async throws -> String
    /// Writes one file relative to the Workspace root.
    ///
    /// - Parameters:
    ///   - workspaceID: The Gnostic-owned Workspace identifier.
    ///   - path: The Workspace-relative path.
    ///   - content: The contents to write.
    /// - Throws: When the file cannot be written.
    func writeFile(workspaceID: UUID, path: String, content: String) async throws
    /// Lists the entries of one Workspace-relative directory.
    ///
    /// - Parameters:
    ///   - workspaceID: The Gnostic-owned Workspace identifier.
    ///   - path: The Workspace-relative directory.
    /// - Returns: The entry names.
    /// - Throws: When the directory cannot be listed.
    func listFiles(workspaceID: UUID, path: String) async throws -> [String]
    /// Deletes one file relative to the Workspace root.
    ///
    /// - Parameters:
    ///   - workspaceID: The Gnostic-owned Workspace identifier.
    ///   - path: The Workspace-relative path.
    /// - Throws: When the file cannot be deleted.
    func deleteFile(workspaceID: UUID, path: String) async throws
}

/// Gnostic's host-owned Workspace consumption service.
///
/// Local Workspaces are opaque ``LocalWorkspace`` capabilities, network
/// Workspaces are resolved through the catalog, and network invocation is
/// delegated to the host-installed ``NetworkWorkspaceInvoking`` seam. The
/// ``AscendantBackendWorkspaceService`` contract remains Foundation-only.
@MainActor
extension AscendantBackendWorkspaceService {
    /// Direct file access, when the host Workspace service offers it.
    nonisolated public var optionalFileService: (any AscendantBackendWorkspaceFileService)? {
        self as? any AscendantBackendWorkspaceFileService
    }

    /// Direct file access, required. Throws the one absent-capability outcome
    /// when the host Workspace service does not offer it.
    ///
    /// - Returns: The file service.
    /// - Throws: ``AscendantBackendError/capabilityUnavailable(_:)``.
    nonisolated public func requireFileService() throws -> any AscendantBackendWorkspaceFileService {
        guard let files = optionalFileService else {
            throw AscendantBackendError.capabilityUnavailable(.workspaceFiles)
        }
        return files
    }
}

final class GnosticWorkspaceBackendService: WorkspaceReferenceUpdating, AscendantBackendWorkspaceFileService, @unchecked Sendable { // SAFETY: @MainActor class; all mutable state is actor-isolated.
    private let localWorkspaces: [UUID: any LocalWorkspace]
    private var references: [UUID: BackendWorkspaceReference]
    private let catalog: NetworkCatalog
    private let networkWorkspaceInvoker: (any NetworkWorkspaceInvoking)?

    init(
        localWorkspaces: [UUID: any LocalWorkspace],
        references: [UUID: BackendWorkspaceReference],
        catalog: NetworkCatalog,
        networkWorkspaceInvoker: (any NetworkWorkspaceInvoking)?
    ) {
        self.localWorkspaces = localWorkspaces
        self.references = references
        self.catalog = catalog
        self.networkWorkspaceInvoker = networkWorkspaceInvoker
    }

    func update(reference: BackendWorkspaceReference) {
        references[reference.id] = reference
    }

    func reference(id: UUID) async -> BackendWorkspaceReference? {
        if let reference = references[id] {
            let status: BackendWorkspaceStatus = localWorkspaces[id] != nil
                ? .available
                : await networkStatus(id: id)
            return BackendWorkspaceReference(
                id: reference.id,
                uri: reference.uri,
                status: status,
                tools: reference.tools,
                location: reference.location,
                createdAt: reference.createdAt
            )
        }
        guard case let .available(providerID, uri) = await catalog.workspaceAttachmentStatus(id: id),
              let descriptor = await catalog.object(id: id, providerID: providerID)?.workspace else {
            return nil
        }
        let projected = WorkspaceReferenceProjection.backendReference(from: descriptor)
        return BackendWorkspaceReference(
            id: projected.id,
            uri: uri,
            status: projected.status,
            tools: projected.tools,
            location: projected.location,
            createdAt: projected.createdAt
        )
    }

    func invoke(_ invocation: BackendWorkspaceInvocation) async throws -> BackendWorkspaceResult {
        guard let reference = await reference(id: invocation.workspaceID), reference.status == .available else {
            throw AscendantBackendError.invalidConfiguration("Workspace \(invocation.workspaceID.uuidString) is unavailable.")
        }
        guard reference.tools.contains(where: { $0.id == invocation.toolID }) else {
            throw AscendantBackendError.invalidConfiguration("Workspace tool '\(invocation.toolID)' is unsupported.")
        }
        if let local = localWorkspaces[invocation.workspaceID] {
            return try await local.executeTool(id: invocation.toolID, parameters: invocation.arguments)
        }
        guard let networkWorkspaceInvoker else {
            throw AscendantBackendError.invalidConfiguration("Network Workspace invocation is unavailable.")
        }
        return try await networkWorkspaceInvoker.invoke(invocation)
    }

    func readFile(workspaceID: UUID, path: String) async throws -> String {
        guard let workspace = localWorkspaces[workspaceID] as? any LocalWorkspaceFileAccess else { throw WorkspaceServiceError.fileAccessNotSupported }
        return try await workspace.readFile(path: path)
    }

    func writeFile(workspaceID: UUID, path: String, content: String) async throws {
        guard let workspace = localWorkspaces[workspaceID] as? any LocalWorkspaceFileAccess else { throw WorkspaceServiceError.fileAccessNotSupported }
        try await workspace.writeFile(path: path, content: content)
    }

    func listFiles(workspaceID: UUID, path: String) async throws -> [String] {
        guard let workspace = localWorkspaces[workspaceID] as? any LocalWorkspaceFileAccess else { throw WorkspaceServiceError.fileAccessNotSupported }
        return try await workspace.listFiles(path: path)
    }

    func deleteFile(workspaceID: UUID, path: String) async throws {
        guard let workspace = localWorkspaces[workspaceID] as? any LocalWorkspaceFileAccess else { throw WorkspaceServiceError.fileAccessNotSupported }
        try await workspace.deleteFile(path: path)
    }

    private func networkStatus(id: UUID) async -> BackendWorkspaceStatus {
        switch await catalog.workspaceAttachmentStatus(id: id) {
        case .available: return .available
        case .unavailable: return .unavailable
        case .ambiguous, .malformed, .unsupported: return .unsupported
        }
    }
}
