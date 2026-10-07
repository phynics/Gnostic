// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticCore
import PKContracts
import PositronicKit

/// PositronicKit-facing conveniences for the bundled echo Workspace.
public extension EchoWorkspace {
    /// Creates an echo Workspace from a PositronicKit Workspace reference.
    ///
    /// - Parameter reference: The PositronicKit Workspace reference.
    init(reference: WorkspaceReference) {
        self.init(reference: PositronicWorkspaceProjection.backendReference(from: reference))
    }
}
