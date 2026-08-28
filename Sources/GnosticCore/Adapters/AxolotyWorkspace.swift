// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKContracts
import PositronicKit

/// A PositronicKit workspace proxy backed by a catalogued Gnostic advertisement.
public struct AxolotyWorkspace: WorkspaceToolProvider, WorkspaceFileProvider, Sendable {
    /// The imported runtime workspace reference.
    public let reference: WorkspaceReference

    /// The PositronicKit workspace identifier.
    public var id: UUID { reference.id }

    private let catalog: NetworkCatalog
    private let invokeRemote: @Sendable (WorkspaceInvocation) async throws -> ToolResult

    /// Creates a remote workspace proxy with its unary invocation transport.
    public init(
        reference: WorkspaceReference,
        catalog: NetworkCatalog,
        invoke: @escaping @Sendable (WorkspaceInvocation) async throws -> ToolResult
    ) {
        self.reference = reference
        self.catalog = catalog
        invokeRemote = invoke
    }

    /// Creates a proxy that invokes the remote provider through Axoloty unary Call/Return.
    @MainActor
    public init(
        reference: WorkspaceReference,
        catalog: NetworkCatalog,
        communication: CommunicationManager,
        timeout: Duration = .seconds(10)
    ) {
        self.init(reference: reference, catalog: catalog) { invocation in
            try await invokeWorkspace(invocation, communication: communication, timeout: timeout)
        }
    }

    /// Returns the current uniquely advertised custom definitions. The catalog lookup
    /// lets a proxy created from a lazy placeholder gain tools when its provider appears.
    public func listTools() async throws -> [ToolReference] {
        let tools = await advertisedReference()?.tools ?? reference.tools
        return tools.compactMap { tool in
            guard case .custom = tool else { return nil }
            return tool
        }
    }

    /// Executes an advertised tool only while its workspace remains uniquely catalogued.
    public func executeTool(id: String, parameters: [String: AnyCodable]) async throws -> ToolResult {
        guard case let .available(providerID, _) = await catalog.workspaceAttachmentStatus(id: self.id) else {
            throw WorkspaceError.connectionFailed
        }
        guard await advertisedReference()?.tools.contains(where: { $0.toolID == id }) == true else {
            throw WorkspaceError.toolExecutionNotSupported
        }
        do {
            return try await invokeRemote(WorkspaceInvocation(workspaceID: self.id, providerID: providerID, toolID: id, arguments: parameters))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Do not expose transport or decode implementation errors through Workspace.
            throw WorkspaceError.connectionFailed
        }
    }

    /// Remote workspace proxies do not expose direct filesystem access.
    public func readFile(path _: String) async throws -> String { throw WorkspaceError.toolExecutionNotSupported }
    /// Remote workspace proxies do not expose direct filesystem access.
    public func writeFile(path _: String, content _: String) async throws { throw WorkspaceError.toolExecutionNotSupported }
    /// Remote workspace proxies do not expose direct filesystem access.
    public func listFiles(path _: String) async throws -> [String] { throw WorkspaceError.toolExecutionNotSupported }
    /// Remote workspace proxies do not expose direct filesystem access.
    public func deleteFile(path _: String) async throws { throw WorkspaceError.toolExecutionNotSupported }

    /// A proxy is healthy only while exactly one available advertisement exists.
    public func healthCheck() async -> Bool {
        if case .available = await catalog.workspaceAttachmentStatus(id: id) { return true }
        return false
    }

    private func advertisedReference() async -> WorkspaceReference? {
        guard case let .available(providerID, _) = await catalog.workspaceAttachmentStatus(id: id),
              let descriptor = await catalog.object(id: id, providerID: providerID)?.workspace
        else { return nil }
        return try? WorkspaceReferenceProjection.reference(from: descriptor)
    }
}

/// Creates catalog-backed remote workspace proxies for PositronicKit's normal resolver path.
public struct AxolotyWorkspaceFactory: WorkspaceFactory, Sendable {
    private let catalog: NetworkCatalog
    private let invoke: @Sendable (WorkspaceInvocation) async throws -> ToolResult

    /// Creates a factory using the remote invocation transport.
    public init(catalog: NetworkCatalog, invoke: @escaping @Sendable (WorkspaceInvocation) async throws -> ToolResult) {
        self.catalog = catalog
        self.invoke = invoke
    }

    /// Creates catalog-backed proxies that route to the selected provider.
    @MainActor
    public init(catalog: NetworkCatalog, communication: CommunicationManager, timeout: Duration = .seconds(10)) {
        self.init(catalog: catalog) { invocation in
            try await invokeWorkspace(invocation, communication: communication, timeout: timeout)
        }
    }

    /// Creates the runtime proxy used by `WorkspaceToolWrapper` and `TimelineToolRegistry`.
    public func create(from reference: WorkspaceReference) throws -> any WorkspaceProvider {
        AxolotyWorkspace(reference: reference, catalog: catalog, invoke: invoke)
    }
}

@MainActor
private func invokeWorkspace(
    _ invocation: WorkspaceInvocation,
    communication: CommunicationManager,
    timeout: Duration
) async throws -> ToolResult {
    guard let providerID = invocation.providerID else {
        throw WorkspaceError.connectionFailed
    }
    let data = try JSONEncoder().encode(invocation)
    let response = try await communication.call(
        operation: GnosticWorkspaceProvider.invocationOperation,
        parameters: String(decoding: data, as: UTF8.self),
        context: ObjectFilter(condition: ObjectFilterCondition(
            property: ObjectFilterProperty("objectId"),
            expression: .equals(FilterOperand(providerID.lowercased()))
        )),
        timeout: timeout
    )
    guard response.sourceId?.lowercased() == providerID.lowercased() else {
        throw WorkspaceError.connectionFailed
    }
    try GnosticProtocol.validatePayload(response.result)
    return try JSONDecoder().decode(ToolResult.self, from: Data(response.result.utf8))
}
