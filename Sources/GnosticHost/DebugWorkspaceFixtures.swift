// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#if DEBUG
import Foundation
@_spi(RuntimeHost) import GnosticCore

/// Explicit, debug-build-only Workspace fixtures for process integration tests.
enum DebugWorkspaceFixtures {
    static func register(in registry: inout WorkspaceAdapterRegistry, environment: [String: String]) {
        guard environment["GNOSTIC_TEST_WORKSPACE_FIXTURE"] == "revocable-peer",
              let healthPath = environment["GNOSTIC_TEST_WORKSPACE_HEALTH_FILE"],
              let invocationPath = environment["GNOSTIC_TEST_WORKSPACE_INVOCATIONS_FILE"] else { return }

        let healthURL = URL(fileURLWithPath: healthPath)
        let invocationURL = URL(fileURLWithPath: invocationPath)
        registry.registerProduct(kind: "test-revocable-peer") { configuration in
            RevocablePeerWorkspace(
                id: configuration.id,
                uri: configuration.uri,
                healthURL: healthURL,
                invocationURL: invocationURL
            )
        }
    }
}

@MainActor
private final class RevocablePeerWorkspace: LocalWorkspace, LocalWorkspaceHealth {
    let reference: BackendWorkspaceReference
    private let healthURL: URL
    private let invocationURL: URL

    var isHealthy: Bool {
        (try? String(contentsOf: healthURL, encoding: .utf8)) == "available"
    }

    init(id: UUID, uri: String, healthURL: URL, invocationURL: URL) {
        self.healthURL = healthURL
        self.invocationURL = invocationURL
        let supplementalTools = (0..<16).map { index in
            BackendWorkspaceTool(
                id: String(format: "peer-tool-%02d", index),
                name: "Peer tool \(index)",
                description: "A paged peer Workspace tool definition used by the two-Node fixture. \(String(repeating: "detail ", count: 8))",
                parametersSchema: .object(["type": .string("object")]),
                requiresPermission: false
            )
        }
        reference = BackendWorkspaceReference(
            id: id,
            uri: uri,
            status: .available,
            tools: [BackendWorkspaceTool(
                id: "search",
                name: "Search",
                description: "Search the remote Workspace fixture",
                parametersSchema: .object(["type": .string("object")]),
                requiresPermission: true
            )] + supplementalTools
        )
    }

    func listTools() async throws -> [BackendWorkspaceTool] { reference.tools }

    func executeTool(id: String, parameters: [String: ManifestJSONValue]) async throws -> BackendWorkspaceResult {
        let currentCount = Int((try? String(contentsOf: invocationURL, encoding: .utf8)) ?? "0") ?? 0
        try String(currentCount + 1).write(to: invocationURL, atomically: true, encoding: .utf8)
        let query: String
        if case let .string(value)? = parameters["query"] { query = value }
        else { query = "missing" }
        return .success("remote workspace result: \(query)")
    }
}
#endif
