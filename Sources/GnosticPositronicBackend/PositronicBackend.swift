// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticProtocol
import PositronicKit

/// Registers the bundled Positronic backend into a neutral runtime adapter
/// bundle.
///
/// The kernel knows the `"positronic"` kind name but owns no Positronic
/// dependency. A composition root that links the backend calls
/// ``register(into:)`` to install the deterministic Workspace kind, the network
/// Workspace invoker, and the durable Timeline store factory.
public enum PositronicBackend {
    /// The manifest kind the bundled backend serves.
    public static var kind: String { AscendantAdapterRegistry.positronicKind }

    /// Installs the backend's kernel-facing seams over `adapters`.
    ///
    /// The Ascendant factory itself is registered separately by the
    /// composition root, because building the bundled adapter needs the
    /// composition's language-model and module configuration.
    ///
    /// - Parameter adapters: The adapter bundle to amend.
    public static func register(into adapters: inout NodeRuntimeAdapters) {
        adapters.workspaces.registerProduct(kind: echoWorkspaceKind) { configuration in
            guard !configuration.uri.isEmpty else {
                throw NodeRuntimeError.invalidWorkspaceURI(configuration.id)
            }
            return EchoWorkspace(reference: BackendWorkspaceReference(
                id: configuration.id,
                uri: configuration.uri,
                status: .available,
                tools: EchoWorkspace.toolDefinitions,
                location: .runtime
            ))
        }
        adapters.networkWorkspaceInvoker = { catalog, communication in
            AxolotyNetworkWorkspaceInvoker(catalog: catalog, communication: communication)
        }
        adapters.timelineStore = { ascendantID, directory in
            let fileURL = directory.appendingPathComponent("\(ascendantID.uuidString.lowercased()).jsonl")
            return BackendTimelineStoreCapability(
                store: try await FileTimelineRuntimeRepository(fileURL: fileURL)
            )
        }
    }

    /// The manifest Workspace kind the backend's deterministic echo product serves.
    public static let echoWorkspaceKind = "echo"
}

public extension AscendantAdapterRegistry {
    /// Registers the bundled Positronic backend with a caller-supplied
    /// language model.
    ///
    /// The kind is fixed to `"positronic"` because this seam always builds a
    /// ``PositronicAscendantAdapter``. Use ``registerBackend(kind:settings:factory:)``
    /// for any other backend.
    ///
    /// - Parameter factory: Supplies the language model for one Ascendant.
    mutating func registerPositronicBackend(
        languageModel factory: @escaping @Sendable (_ ascendant: NodeManifest.Ascendant, _ backend: AscendantBackendConfiguration) -> any LLMStreamClient
    ) {
        registerBackend(
            kind: Self.positronicKind,
            settings: PositronicAscendantAdapter.settingsSchema
        ) { ascendant, backend, services, timelines in
            try await PositronicAscendantAdapter(
                ascendant: ascendant,
                backend: backend,
                services: services,
                timelines: timelines,
                languageModel: factory(ascendant, backend)
            )
        }
    }
}
