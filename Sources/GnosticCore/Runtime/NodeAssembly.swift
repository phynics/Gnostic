// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticProtocol

/// Builds the immutable host resources needed by a NodeRuntime. The runtime
/// facade consumes these products and owns only public delegation and service
/// composition; adapter materialization and container resolution stay here.
@MainActor
struct NodeAssembly {
    struct WorkspaceProducts {
        let references: [UUID: BackendWorkspaceReference]
        let workspaces: [UUID: any LocalWorkspace]
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
        var references: [UUID: BackendWorkspaceReference] = [:]
        var workspaces: [UUID: any LocalWorkspace] = [:]
        for configuration in plan.workspaces {
            let workspace = try adapters.workspaces.makeWorkspace(for: configuration)
            let reference = workspace.reference
            guard reference.id == configuration.id,
                  reference.uri == configuration.uri else {
                throw NodeRuntimeError.invalidWorkspaceURI(configuration.id)
            }
            references[configuration.id] = reference
            workspaces[configuration.id] = workspace
        }
        for timeline in plan.timelines {
            for attachment in timeline.attachments where attachment.scope == .network {
                guard let uriString = attachment.uri, !uriString.isEmpty else {
                    throw NodeRuntimeError.invalidWorkspaceURI(attachment.workspaceID)
                }
                references[attachment.workspaceID] = BackendWorkspaceReference(
                    id: attachment.workspaceID,
                    uri: uriString,
                    status: .unavailable,
                    location: .attached
                )
            }
        }
        return WorkspaceProducts(references: references, workspaces: workspaces)
    }

    static func resolveInfrastructure(
        for plan: NodeLaunchPlan,
        products: WorkspaceProducts,
        adapters: NodeRuntimeAdapters
    ) throws -> Infrastructure {
        let resolvedContainer = try Container.resolve(
            components: Components(
                controllers: ["ObjectLifecycleController": ObjectLifecycleController.self],
                objectTypes: [GnosticAscendantObject.self, GnosticRuntimeInstanceObject.self, GnosticTimelineObject.self, GnosticWorkspaceObject.self, GnosticWorkspaceToolObject.self]
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
              let lifecycle = resolvedContainer.controller(named: "ObjectLifecycleController") else {
            resolvedContainer.shutdown()
            throw NodeRuntimeError.notRunning
        }
        let catalog = NetworkCatalog()
        let subscription = GnosticSubscription(catalog: catalog, communicationManager: communication)
        let networkWorkspaceInvoker = adapters.networkWorkspaceInvoker.flatMap { makeInvoker in
            makeInvoker(catalog, communication)
        }
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
                networkWorkspaceInvoker: networkWorkspaceInvoker
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
        retirementSupervisor: BackendRetirementSupervisor,
        runtimeTimelineDirectory: URL? = nil,
        timelineJournals: TimelineJournalStore? = nil
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
        var timelineStoreCapabilities: [UUID: any AscendantBackendOptionalCapability] = [:]

        do {
            var journalProjections: [UUID: TimelineJournalTimelineProjection] = [:]
            if let timelineJournals {
                for timeline in plan.timelines {
                    try await timelineJournals.ensureTimelineCreated(
                        timelineID: timeline.id,
                        title: timeline.title,
                        runtimeInstanceID: timeline.operatingAscendantID,
                        attachments: timeline.attachments
                    )
                }
                journalProjections = try await timelineJournals.timelineProjections()
            }
            for ascendant in plan.ascendants {
                guard let backend = plan.backend(for: ascendant.id) else {
                    throw NodeRuntimeError.unsupportedAscendantKind(ascendant.kind)
                }
                var timelineConfigurations = plan.timelines.filter { $0.operatingAscendantID == ascendant.id }
                for index in timelineConfigurations.indices {
                    let configuration = timelineConfigurations[index]
                    guard let projection = journalProjections[configuration.id] else { continue }
                    if let runtimeInstanceID = projection.runtimeInstanceID,
                       runtimeInstanceID != ascendant.id {
                        throw NodeRuntimeError.unknownAscendant(runtimeInstanceID)
                    }
                    timelineConfigurations[index] = try Self.replaying(
                        configuration,
                        from: projection
                    )
                }
                let configuredIDs = Set(timelineConfigurations.map(\.id))
                for (timelineID, projection) in journalProjections
                    where !configuredIDs.contains(timelineID) && projection.runtimeInstanceID == ascendant.id {
                    timelineConfigurations.append(NodeManifest.Timeline(
                        id: timelineID,
                        title: projection.title,
                        kind: "timeline",
                        operatingAscendantID: ascendant.id,
                        attachments: try Self.manifestAttachments(from: projection.attachments),
                        project: Self.replayedProject(projection.latestSession) ?? .scratch
                    ))
                }
                let lease = UUID.makeVersion4()
                let attachmentCapability = BackendWorkspaceAttachmentCapability()
                specs[ascendant.id] = .init(ascendant: ascendant, configuration: backend)
                leases[ascendant.id] = lease
                attachmentCapabilities.append((ascendant.id, lease, attachmentCapability))
                var optionalCapabilities: [any AscendantBackendOptionalCapability] = [workspaceCapability, attachmentCapability]
                if let timelineJournals {
                    optionalCapabilities.append(TimelineJournalRecorder(journals: timelineJournals))
                }
                if let runtimeTimelineDirectory, let makeTimelineStore = adapters.timelineStore {
                    let capability = try await makeTimelineStore(ascendant.id, runtimeTimelineDirectory)
                    timelineStoreCapabilities[ascendant.id] = capability
                    optionalCapabilities.append(capability)
                }
                let services = AscendantBackendServices(
                    workspace: infrastructure.backendWorkspaceService,
                    permission: permissionCoordinator,
                    optionalCapabilities: optionalCapabilities
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
            if let timelineJournals {
                for timeline in operatedTimelines {
                    let configured = plan.timelines.first(where: { $0.id == timeline.id })
                    try await timelineJournals.ensureTimelineCreated(
                        timelineID: timeline.id,
                        title: timeline.title,
                        runtimeInstanceID: timeline.attachedAscendantID,
                        attachments: configured?.attachments ?? []
                    )
                }
                journalProjections = try await timelineJournals.timelineProjections()
            }
            let registry = try NodeRegistry(
                plan: plan,
                operatedTimelines: operatedTimelines,
                backendLeases: leases,
                timelineJournals: timelineJournals,
                timelineJournalProjections: journalProjections
            )
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
                backendTimelineCapabilities: timelineStoreCapabilities,
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
        let normalized = broker.normalized()
        let options = MQTTClientOptions(
            host: normalized.host,
            port: UInt16(clamping: normalized.port),
            shouldTryMDNSDiscovery: false,
            autoReconnect: false
        )
        options.username = normalized.username
        options.password = normalized.password
        return options
    }

    private static func replaying(
        _ configuration: NodeManifest.Timeline,
        from projection: TimelineJournalTimelineProjection
    ) throws -> NodeManifest.Timeline {
        NodeManifest.Timeline(
            id: configuration.id,
            title: projection.title,
            kind: configuration.kind,
            operatingAscendantID: configuration.operatingAscendantID,
            flags: configuration.flags,
            attachments: try manifestAttachments(from: projection.attachments),
            project: replayedProject(projection.latestSession) ?? configuration.project
        )
    }

    private static func replayedProject(
        _ session: TimelineJournalSessionProjection?
    ) -> Project? {
        guard let session, let projectKind = session.projectKind else { return nil }
        switch projectKind {
        case .local:
            return .local(session.cwd)
        case .scratch:
            return .scratch
        }
    }

    private static func manifestAttachments(
        from attachments: [TimelineJournalWorkspaceAttachment]
    ) throws -> [NodeManifest.WorkspaceAttachment] {
        try attachments.map { attachment in
            if attachment.scope == .network {
                guard let uri = attachment.uri, !uri.isEmpty else {
                    throw NodeRuntimeError.invalidWorkspaceURI(attachment.workspaceID)
                }
                return .network(attachment.workspaceID, uri: uri)
            }
            return .local(attachment.workspaceID)
        }
    }
}
