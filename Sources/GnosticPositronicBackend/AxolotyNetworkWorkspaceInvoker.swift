// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore
import GnosticProtocol
import PKContracts
import PositronicKit

/// Invokes one tool on a network Workspace the kernel knows only through its
/// catalog descriptor.
///
/// The kernel routes a ``BackendWorkspaceInvocation`` to this backend-owned
/// transport, which resolves the descriptor, projects it into a PositronicKit
/// reference, and performs the unary Axoloty call. Native values never cross
/// back into the kernel.
@MainActor
public final class AxolotyNetworkWorkspaceInvoker: NetworkWorkspaceInvoking {
    private let catalog: NetworkCatalog
    private let communication: CommunicationManager
    private let timeout: Duration

    /// Creates a network Workspace invoker over one node connection.
    ///
    /// - Parameters:
    ///   - catalog: The node's catalog of advertised objects.
    ///   - communication: The node's communication manager.
    ///   - timeout: The per-invocation timeout.
    public init(catalog: NetworkCatalog, communication: CommunicationManager, timeout: Duration = .seconds(10)) {
        self.catalog = catalog
        self.communication = communication
        self.timeout = timeout
    }

    /// Resolves the advertised Workspace, then invokes one of its tools.
    ///
    /// - Parameter invocation: The Workspace, tool, and arguments.
    /// - Returns: The tool result, including a failure message when the remote
    ///   tool reported one.
    /// - Throws: When the Workspace is not available or the transport fails.
    public func invoke(_ invocation: BackendWorkspaceInvocation) async throws -> BackendWorkspaceResult {
        guard case let .available(providerID, _) = await catalog.workspaceAttachmentStatus(id: invocation.workspaceID),
              let descriptor = await catalog.object(id: invocation.workspaceID, providerID: providerID)?.workspace else {
            throw WorkspaceServiceError.connectionFailed
        }
        let reference = try PositronicWorkspaceProjection.reference(from: descriptor)
        let proxy = AxolotyWorkspace(reference: reference, catalog: catalog, communication: communication, timeout: timeout)
        let result = try await proxy.executeTool(
            id: invocation.toolID,
            parameters: invocation.arguments.mapValues(Self.anyCodable)
        )
        return BackendWorkspaceResult(
            message: result.isSuccess ? result.output : (result.error ?? "Workspace tool failed.")
        )
    }

    private static func anyCodable(_ value: ManifestJSONValue) -> AnyCodable {
        switch value {
        case let .string(value): return AnyCodable(value)
        case let .number(value): return AnyCodable(value)
        case let .bool(value): return AnyCodable(value)
        case let .object(value): return AnyCodable(value.mapValues(anyCodable))
        case let .array(value): return AnyCodable(value.map(anyCodable))
        case .null: return AnyCodable(NSNull())
        }
    }
}
