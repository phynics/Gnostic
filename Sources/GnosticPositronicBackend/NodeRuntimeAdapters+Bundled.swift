// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticCore
import PositronicKit

public extension NodeRuntimeAdapters {
    /// The bundled adapter bundle: the deterministic `echo` Workspace, the
    /// network Workspace invoker, the durable Timeline store factory, and the
    /// bundled Positronic backend bound to an unconfigured language model.
    ///
    /// A test or an embedding that only needs the kernel graph uses this value.
    /// A production composition root installs a configured model through
    /// ``AscendantAdapterRegistry/registerPositronicBackend(languageModel:)``
    /// instead, so the bundled seam never serves a live Turn.
    ///
    /// - Returns: A neutral adapter bundle with the bundled seams registered.
    static var bundled: NodeRuntimeAdapters {
        var adapters = NodeRuntimeAdapters.default
        PositronicBackend.register(into: &adapters)
        adapters.ascendants.registerPositronicBackend { _, _ in UnconfiguredLLMService() }
        return adapters
    }
}
