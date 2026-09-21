// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The model tier a Positronic contribution may request from its dedicated
/// runtime model service.
public enum PositronicContributionModelTier: String, Sendable, Equatable, CaseIterable {
    case primary
    case utility
    case fast
}

/// A narrow model boundary for Positronic contributions.
///
/// The protocol deliberately carries Gnostic-owned values only. The bundled
/// Positronic adapter bridges it to its private model client at composition
/// time, so a contribution cannot receive the outer Turn client or provider
/// credentials.
public protocol PositronicContributionModelService: Sendable {
    func generate(prompt: String, tier: PositronicContributionModelTier) async throws -> String
}

/// Read-only file access exposed to a selected Positronic contribution.
///
/// Workspace objects, native tool values, and raw filesystem paths stay behind
/// the host adapter. Callers identify an attached Workspace and use paths
/// relative to that Workspace only.
@MainActor
public protocol PositronicContributionWorkspaceReader: Sendable {
    func reference(id: UUID) async -> BackendWorkspaceReference?
    func readFile(workspaceID: UUID, path: String) async throws -> String
    func listFiles(workspaceID: UUID, path: String) async throws -> [String]
}

/// Capabilities bound once for one Positronic Ascendant at startup.
///
/// The context has no global lookup, credentials, mutable configuration, or
/// raw path access. An absent context preserves the pre-extension construction
/// path used by ordinary Positronic Ascendants.
public struct PositronicContributionRuntimeContext: Sendable {
    public let workspaceReader: (any PositronicContributionWorkspaceReader)?
    public let permission: any AscendantBackendPermissionService
    public let modelService: (any PositronicContributionModelService)?
    public let allowedWorkspaceIDs: Set<UUID>

    public init(
        workspaceReader: (any PositronicContributionWorkspaceReader)?,
        permission: any AscendantBackendPermissionService,
        modelService: (any PositronicContributionModelService)?,
        allowedWorkspaceIDs: Set<UUID>
    ) {
        self.workspaceReader = workspaceReader
        self.permission = permission
        self.modelService = modelService
        self.allowedWorkspaceIDs = allowedWorkspaceIDs
    }

    /// Binds host services while keeping the optional file capability narrow.
    @MainActor
    public init(
        services: AscendantBackendServices,
        modelService: (any PositronicContributionModelService)?,
        allowedWorkspaceIDs: Set<UUID>
    ) {
        self.init(
            workspaceReader: services.workspace.map(BackendWorkspaceFileReader.init(service:)),
            permission: services.permission,
            modelService: modelService,
            allowedWorkspaceIDs: allowedWorkspaceIDs
        )
    }
}

/// Host bridge used by the contribution context. The cast is intentionally
/// performed only when a file operation is requested, because file access is
/// optional on the mandatory Workspace service.
@MainActor
private struct BackendWorkspaceFileReader: PositronicContributionWorkspaceReader {
    let service: any AscendantBackendWorkspaceService

    func reference(id: UUID) async -> BackendWorkspaceReference? {
        await service.reference(id: id)
    }

    func readFile(workspaceID: UUID, path: String) async throws -> String {
        guard let fileService = service as? any AscendantBackendWorkspaceFileService else {
            throw AscendantBackendError.invalidConfiguration("Workspace does not expose read-only file access.")
        }
        return try await fileService.readFile(workspaceID: workspaceID, path: path)
    }

    func listFiles(workspaceID: UUID, path: String) async throws -> [String] {
        guard let fileService = service as? any AscendantBackendWorkspaceFileService else {
            throw AscendantBackendError.invalidConfiguration("Workspace does not expose read-only file access.")
        }
        return try await fileService.listFiles(workspaceID: workspaceID, path: path)
    }
}
