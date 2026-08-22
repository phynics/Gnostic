// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKContracts
import PositronicKit

/// Builds the immutable host resources needed by a NodeRuntime. The runtime
/// facade consumes these products and owns only public delegation and service
/// composition; adapter materialization and container resolution stay here.
@MainActor
struct NodeAssembly {
    struct WorkspaceProducts {
        let references: [UUID: WorkspaceReference]
        let workspaces: [UUID: any Workspace]
    }

    struct Infrastructure {
        let container: Container
        let communication: CommunicationManager
        let lifecycle: ObjectLifecycleController
        let catalog: NetworkCatalog
        let subscription: GnosticSubscription
        let backendWorkspaceService: GnosticWorkspaceBackendService
    }

    struct BackendProducts {
        let registry: NodeRegistry
        let supervisor: AscendantBackendSupervisor
        let attachmentCapabilities: [(ascendantID: UUID, lease: UUID, capability: BackendWorkspaceAttachmentCapability)]
    }

    static func validate(_ plan: NodeLaunchPlan, adapters: NodeRuntimeAdapters) throws {
        let manifest = NodeManifest(
            schemaVersion: NodeManifest.currentSchemaVersion,
            broker: plan.broker,
            node: plan.node,
            ascendants: plan.ascendants,
            timelines: plan.timelines,
            workspaces: plan.workspaces
        )
        try manifest.validate()
        try adapters.ascendants.validate(kinds: plan.ascendants.map { plan.backend(for: $0.id)?.kind ?? $0.kind })
        try adapters.workspaces.validate(kinds: plan.workspaces.map(\.kind))
    }

    static func materializeWorkspaces(
        _ plan: NodeLaunchPlan,
        adapters: NodeRuntimeAdapters
    ) async throws -> WorkspaceProducts {
        var references: [UUID: WorkspaceReference] = [:]
        var workspaces: [UUID: any Workspace] = [:]
        for configuration in plan.workspaces {
            guard let uri = WorkspaceURI(parsing: configuration.uri) else {
                throw NodeRuntimeError.invalidWorkspaceURI(configuration.id)
            }
            let workspace = try adapters.workspaces.makeWorkspace(for: configuration)
            let reference: WorkspaceReference
            if adapters.workspaces.usesProductFactory(kind: configuration.kind) {
                let ownedReference = workspace.reference
                guard ownedReference.id == configuration.id,
                      ownedReference.uri.description == uri.description else {
                    throw NodeRuntimeError.invalidWorkspaceURI(configuration.id)
                }
                reference = ownedReference
            } else {
                reference = WorkspaceReference(
                    id: configuration.id,
                    uri: uri,
                    location: .runtime,
                    tools: try await workspace.listTools()
                )
            }
            references[configuration.id] = reference
            workspaces[configuration.id] = workspace
        }
        for timeline in plan.timelines {
            for attachment in timeline.attachments where attachment.scope == .network {
                guard let uriString = attachment.uri, let uri = WorkspaceURI(parsing: uriString) else {
                    throw NodeRuntimeError.invalidWorkspaceURI(attachment.workspaceID)
                }
                references[attachment.workspaceID] = WorkspaceReference(
                    id: attachment.workspaceID,
                    uri: uri,
                    location: .attached,
                    tools: []
                )
            }
        }
        return WorkspaceProducts(references: references, workspaces: workspaces)
    }

    static func resolveInfrastructure(
        for plan: NodeLaunchPlan,
        products: WorkspaceProducts
    ) throws -> Infrastructure {
        let resolvedContainer = try Container.resolve(
            components: Components(
                controllers: ["ObjectLifecycleController": ObjectLifecycleController.self],
                objectTypes: [GnosticAscendantObject.self, GnosticTimelineObject.self, GnosticWorkspaceObject.self]
            ),
            configuration: Configuration(
                common: CommonOptions(agentIdentity: ["name": "gnostic-node-\(plan.nodeID.uuidString.lowercased())"]),
                communication: CommunicationOptions(
                    namespace: plan.broker.namespace,
                    shouldEnableCrossNamespacing: false,
                    mqttClientOptions: mqttOptions(for: plan.broker),
                    shouldAutoStart: false
                )
            )
        )
        guard let communication = resolvedContainer.communicationManager,
              let lifecycle = resolvedContainer.getController(name: "ObjectLifecycleController") as? ObjectLifecycleController else {
            resolvedContainer.shutdown()
            throw NodeRuntimeError.notRunning
        }
        let catalog = NetworkCatalog()
        let subscription = GnosticSubscription(catalog: catalog, communicationManager: communication)
        return Infrastructure(
            container: resolvedContainer,
            communication: communication,
            lifecycle: lifecycle,
            catalog: catalog,
            subscription: subscription,
            backendWorkspaceService: GnosticWorkspaceBackendService(
                localWorkspaces: products.workspaces,
                references: products.references,
                catalog: catalog,
                communication: communication
            )
        )
    }

    static func buildBackends(
        for plan: NodeLaunchPlan,
        adapters: NodeRuntimeAdapters,
        infrastructure: Infrastructure,
        permissionCoordinator: AscendantPermissionCoordinator,
        lifetime: NodeRuntimeLifetime,
        projectionRelay: NodeProjectionRelay,
        retirementSupervisor: BackendRetirementSupervisor
    ) async throws -> BackendProducts {
        var operatedTimelines: [AscendantRuntimeTimeline] = []
        var identities: [AscendantBackendIdentity] = []
        let backendDiscovery = AxolotyWorkspaceDiscovery(
            catalog: infrastructure.catalog,
            subscription: infrastructure.subscription,
            communication: infrastructure.communication
        )
        let workspaceCapability = BackendWorkspaceDiscoveryCapability(discovery: backendDiscovery)
        var specs: [UUID: AscendantBackendSupervisor.BackendSpec] = [:]
        var leases: [UUID: UUID] = [:]
        var instances: [UUID: any AscendantBackend] = [:]
        var health: [UUID: AscendantBackendHealth] = [:]
        var attachmentCapabilities: [(ascendantID: UUID, lease: UUID, capability: BackendWorkspaceAttachmentCapability)] = []

        do {
            for ascendant in plan.ascendants {
                guard let backend = plan.backend(for: ascendant.id) else {
                    throw NodeRuntimeError.unsupportedAscendantKind(ascendant.kind)
                }
                let timelineConfigurations = plan.timelines.filter { $0.operatingAscendantID == ascendant.id }
                let lease = UUID.makeVersion4()
                let attachmentCapability = BackendWorkspaceAttachmentCapability()
                specs[ascendant.id] = .init(ascendant: ascendant, configuration: backend)
                leases[ascendant.id] = lease
                attachmentCapabilities.append((ascendant.id, lease, attachmentCapability))
                let services = AscendantBackendServices(
                    workspace: infrastructure.backendWorkspaceService,
                    permission: permissionCoordinator,
                    optionalCapabilities: [workspaceCapability, attachmentCapability]
                )
                let instance = try await adapters.ascendants.makeBackend(
                    for: ascendant,
                    backend: backend,
                    services: services,
                    timelines: timelineConfigurations
                )
                instances[ascendant.id] = instance
                try instance.validateConfiguration()
                health[ascendant.id] = .healthy
                identities.append(instance.identity)
                operatedTimelines += try await instance.operatedTimelines()
            }
            let registry = try NodeRegistry(plan: plan, operatedTimelines: operatedTimelines, backendLeases: leases)
            let supervisor = AscendantBackendSupervisor(
                plan: plan,
                adapters: adapters,
                registry: registry,
                lifetime: lifetime,
                backendWorkspaceService: infrastructure.backendWorkspaceService,
                backendRetirementSupervisor: retirementSupervisor,
                permissionCoordinator: permissionCoordinator,
                projectionRelay: projectionRelay,
                backendWorkspaceCapability: workspaceCapability,
                ascendantAdapters: instances,
                backendIdentities: identities,
                backendSpecs: specs,
                backendHealth: health,
                backendLeases: leases
            )
            return BackendProducts(
                registry: registry,
                supervisor: supervisor,
                attachmentCapabilities: attachmentCapabilities
            )
        } catch {
            let backends = instances.map { (id: $0.key, backend: $0.value) }
            await retirementSupervisor.retire(backends, stage: .initializationRollback)
            throw error
        }
    }

    private static func mqttOptions(for broker: NodeManifest.Broker) -> MQTTClientOptions {
        let options = MQTTClientOptions(
            host: broker.host,
            port: UInt16(clamping: broker.port),
            shouldTryMDNSDiscovery: false,
            autoReconnect: false
        )
        options.username = broker.username
        options.password = broker.password
        return options
    }
}
