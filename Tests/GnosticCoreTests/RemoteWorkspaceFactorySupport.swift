// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
@testable import GnosticCore
import PKContracts
import PositronicKit

/// Test-only `WorkspaceFactory` that builds catalog-backed remote proxies, so
/// PositronicKit's resolver path can attach a discovered Workspace in tests.
struct RemoteWorkspaceFactory: WorkspaceFactory, Sendable {
    let catalog: NetworkCatalog
    let invoke: @Sendable (WorkspaceInvocation) async throws -> ToolResult

    init(catalog: NetworkCatalog, invoke: @escaping @Sendable (WorkspaceInvocation) async throws -> ToolResult) {
        self.catalog = catalog
        self.invoke = invoke
    }

    func create(from reference: WorkspaceReference) throws -> any WorkspaceProvider {
        AxolotyWorkspace(reference: reference, catalog: catalog, invoke: invoke)
    }
}
