// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore

@MainActor
final class RunnerRuntime {
    let container: Container
    let communication: CommunicationManager
    let lifecycle: ObjectLifecycleController

    init(configuration: RunnerConfiguration) throws {
        container = try Container.resolve(
            components: Components(controllers: ["ObjectLifecycleController": ObjectLifecycleController.self], objectTypes: [GnosticAscendantObject.self, GnosticTimelineObject.self, GnosticWorkspaceObject.self]),
            configuration: Configuration(
                common: CommonOptions(agentIdentity: ["name": "gnostic-runner"]),
                communication: CommunicationOptions(namespace: configuration.namespace, shouldEnableCrossNamespacing: false, mqttClientOptions: MQTTClientOptions(host: configuration.host, port: UInt16(configuration.port), shouldTryMDNSDiscovery: false, autoReconnect: false), shouldAutoStart: false)
            )
        )
        communication = try container.communicationManager.unwrap()
        lifecycle = try container.getController(name: "ObjectLifecycleController").unwrap()
    }

    func start() async throws { try await container.startAndWaitUntilReady() }
    func shutdown() { container.shutdown() }
}

private enum RunnerRuntimeError: Error {
    case missingRuntimeComponent
}

private extension Optional {
    func unwrap() throws -> Wrapped {
        guard let self else { throw RunnerRuntimeError.missingRuntimeComponent }
        return self
    }
}
