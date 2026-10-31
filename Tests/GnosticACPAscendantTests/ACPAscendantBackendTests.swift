// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import GnosticACPAscendant
import GnosticAscendantConformance
@_spi(RuntimeHost) import GnosticCore
import GnosticProtocol
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("ACP Ascendant backend", .serialized)
struct ACPAscendantBackendTests {
    private actor RecordingPermissionService: AscendantBackendPermissionService {
        let decision: AscendantPermissionDecision
        private(set) var requests: [BackendPermissionRequest] = []

        init(decision: AscendantPermissionDecision) {
            self.decision = decision
        }

        func requestApproval(for request: BackendPermissionRequest) async -> AscendantPermissionDecision {
            requests.append(request)
            return decision
        }
    }

    private actor JournalFailingPermissionService: AscendantBackendPermissionService {
        let journal: TimelineJournal
        private(set) var injectedFailure = false

        init(journal: TimelineJournal) { self.journal = journal }

        func requestApproval(for request: BackendPermissionRequest) async -> AscendantPermissionDecision {
            do {
                let url = await journal.fileURL
                try FileManager.default.removeItem(at: url)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                do { try await journal.append(.timelineRenamed(title: "write fault")) }
                catch { injectedFailure = true }
            } catch { return .unavailable(reason: "faultInjectionFailed") }
            return .approved
        }
    }

    @MainActor
    private final class GatewayWorkspaceService: AscendantBackendWorkspaceService {
        var workspaceReference: BackendWorkspaceReference
        private(set) var invocations: [BackendWorkspaceInvocation] = []

        init(workspaceReference: BackendWorkspaceReference) {
            self.workspaceReference = workspaceReference
        }

        func reference(id: UUID) async -> BackendWorkspaceReference? {
            id == workspaceReference.id ? workspaceReference : nil
        }

        func invoke(_ invocation: BackendWorkspaceInvocation) async throws -> BackendWorkspaceResult {
            invocations.append(invocation)
            return .success("workspace result")
        }
    }

    private actor BackendFactoryCount {
        private(set) var value = 0

        func increment() { value += 1 }
    }

    private actor DelayedPermissionService: AscendantBackendPermissionService {
        private var decisionContinuation: CheckedContinuation<AscendantPermissionDecision, Never>?
        private var receivedRequest: BackendPermissionRequest?
        private(set) var cancellationCount = 0

        func requestApproval(for request: BackendPermissionRequest) async -> AscendantPermissionDecision {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    receivedRequest = request
                    decisionContinuation = continuation
                }
            } onCancel: {
                Task { await self.recordCancellation() }
            }
        }

        func waitForRequest(timeout: Duration = .seconds(5)) async -> BackendPermissionRequest? {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if let receivedRequest { return receivedRequest }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return receivedRequest
        }

        func resolve(_ decision: AscendantPermissionDecision) {
            decisionContinuation?.resume(returning: decision)
            decisionContinuation = nil
        }

        private func recordCancellation() { cancellationCount += 1 }
    }

    @MainActor
    private func backend(
        settings: [String: ManifestJSONValue] = ["command": .string("opencode")],
        secrets: [String: ManifestJSONValue] = [:],
        timelines: [NodeManifest.Timeline] = [],
        ascendantID: UUID = UUID(),
        permission: any AscendantBackendPermissionService = AscendantBackendServices.empty.permission,
        workspace: (any AscendantBackendWorkspaceService)? = nil,
        optionalCapabilities: [any AscendantBackendOptionalCapability] = [],
        protocolTimeoutSeconds: TimeInterval = 30,
        promptTimeoutSeconds: TimeInterval = 60 * 60,
        cancellationSettleSeconds: TimeInterval = ACPAscendantBackend.defaultCancellationSettleSeconds
    ) throws -> ACPAscendantBackend {
        let ascendant = NodeManifest.Ascendant(
            id: ascendantID,
            name: "External agent",
            defaultTimelineID: timelines.first?.id ?? UUID(),
            backend: .init(kind: ACPAscendantBackend.kind, settings: settings, secrets: secrets)
        )
        return try ACPAscendantBackend(
            ascendant: ascendant,
            configuration: ascendant.backend,
            services: AscendantBackendServices(
                workspace: workspace,
                permission: permission,
                optionalCapabilities: optionalCapabilities
            ),
            timelines: timelines,
            protocolTimeoutSeconds: protocolTimeoutSeconds,
            promptTimeoutSeconds: promptTimeoutSeconds,
            cancellationSettleSeconds: cancellationSettleSeconds
        )
    }

    @Test("raw ACP updates preserve unknown kinds and _meta in the Timeline journal")
    @MainActor
    func rawACPUpdatesReachTimelineJournal() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let runtimeID = UUID()
        let nodeID = UUID()
        let configuration = AscendantBackendConfiguration(
            kind: ACPAscendantBackend.kind,
            settings: try fixtureSettings(stateHome: stateHome.url)
        )
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "acp-raw-journal-\(UUID().uuidString.lowercased())"),
            node: .init(id: nodeID),
            ascendants: [.init(id: runtimeID, name: "Journal fixture", defaultTimelineID: timelineID, backend: configuration)],
            timelines: [.init(id: timelineID, title: "Journaled ACP", operatingAscendantID: runtimeID)]
        )
        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.registerBackend(
            kind: ACPAscendantBackend.kind,
            settings: ACPAscendantBackend.settingsSchema
        ) { ascendant, backendConfiguration, services, timelines in
            try ACPAscendantBackend(
                ascendant: ascendant,
                configuration: backendConfiguration,
                services: services,
                timelines: timelines
            )
        }
        let journalDirectory = stateHome.url.appendingPathComponent("timeline-journals", isDirectory: true)
        let runtime = try await NodeRuntime(
            plan: manifest.compileLaunchPlan(),
            adapters: adapters,
            timelineJournalDirectory: journalDirectory
        )
        try await runtime.start()
        defer { Task { @MainActor in await runtime.shutdown() } }

        _ = try await runtime.turn(.init(
            message: "[fixture:unknown-update]",
            timelineID: timelineID,
            clientTurnID: "raw-acp"
        ))
        await runtime.shutdown()

        let nodeJournalDirectory = journalDirectory.appendingPathComponent(nodeID.uuidString.lowercased(), isDirectory: true)
        let fileURL = TimelineJournalStore.fileURL(for: timelineID, in: nodeJournalDirectory)
        let records = try AppendOnlyEventLog<TimelineJournalRecord>(fileURL: fileURL)
            .scan()
            .records
            .map(\.payload)
        #expect(records.contains { record in
            if case let .timelineCreated(title, runtimeInstanceID, _) = record.payload {
                return title == "Journaled ACP" && runtimeInstanceID == runtimeID
            }
            return false
        })
        #expect(records.contains { record in
            if case let .turnAdmitted(clientTurnID, _, _, _, _) = record.payload {
                return clientTurnID == "raw-acp"
            }
            return false
        })
        #expect(records.contains { record in
            if case let .sessionTransition(_, recordedRuntimeID, state, projectKind, cwd) = record.payload {
                return recordedRuntimeID == runtimeID && state == .live && projectKind != nil && !cwd.isEmpty
            }
            return false
        })
        let rawUpdate = try #require(records.first { record in
            if case let .acpUpdate(_, update) = record.payload {
                return update.clientTurnID == "raw-acp" && update.update.updateKind == "vendor_future_update"
            }
            return false
        })
        guard case let .acpUpdate(_, turnUpdate) = rawUpdate.payload,
              case let .other(kind, fields) = turnUpdate.update else {
            Issue.record("Expected the unknown ACP update to remain a raw extensible update")
            return
        }
        #expect(kind == "vendor_future_update")
        #expect(fields["_meta"] == .object(["trace_id": .string("fixture-raw-meta")]))
        #expect(fields["extension"] == .object(["phase": .string("fixture")]))
    }

    @Test("runtime Timeline genesis is journaled before its ACP Session")
    @MainActor
    func runtimeTimelineGenesisPrecedesSession() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let nodeID = UUID()
        let runtimeID = UUID()
        let configuredTimelineID = UUID()
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "acp-genesis-order-\(UUID().uuidString.lowercased())"),
            node: .init(id: nodeID),
            ascendants: [.init(
                id: runtimeID,
                name: "Genesis fixture",
                defaultTimelineID: configuredTimelineID,
                backend: .init(
                    kind: ACPAscendantBackend.kind,
                    settings: try fixtureSettings(stateHome: stateHome.url)
                )
            )],
            timelines: [.init(
                id: configuredTimelineID,
                title: "Configured",
                operatingAscendantID: runtimeID
            )]
        )
        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.registerBackend(
            kind: ACPAscendantBackend.kind,
            settings: ACPAscendantBackend.settingsSchema
        ) { ascendant, configuration, services, timelines in
            try ACPAscendantBackend(
                ascendant: ascendant,
                configuration: configuration,
                services: services,
                timelines: timelines
            )
        }
        let journalDirectory = stateHome.url.appendingPathComponent("timeline-journals", isDirectory: true)
        let runtime = try await NodeRuntime(
            plan: manifest.compileLaunchPlan(),
            adapters: adapters,
            timelineJournalDirectory: journalDirectory
        )
        try await runtime.start()
        defer { Task { @MainActor in await runtime.shutdown() } }

        let created = try await runtime.createTimeline(title: "Created", ascendantID: runtimeID)
        _ = try await runtime.turn(.init(
            message: "first Turn",
            timelineID: created.timelineID,
            clientTurnID: "first-runtime-turn"
        ))
        await runtime.shutdown()

        let nodeJournalDirectory = journalDirectory.appendingPathComponent(nodeID.uuidString.lowercased(), isDirectory: true)
        let fileURL = TimelineJournalStore.fileURL(for: created.timelineID, in: nodeJournalDirectory)
        let payloads = try AppendOnlyEventLog<TimelineJournalRecord>(fileURL: fileURL)
            .scan()
            .records
            .map(\.payload.payload)
        let genesisIndex = try #require(payloads.firstIndex { if case .timelineCreated = $0 { return true }; return false })
        let sessionIndex = try #require(payloads.firstIndex { if case .sessionTransition = $0 { return true }; return false })
        #expect(genesisIndex < sessionIndex)
    }

    @Test("journaled Timeline identity survives when the ACP Runtime no longer lists its Session")
    @MainActor
    func journalRestoresTimelineWithoutRuntimeSession() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let nodeID = UUID()
        let runtimeID = UUID()
        let configuredTimelineID = UUID()
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "acp-timeline-recovery-\(UUID().uuidString.lowercased())"),
            node: .init(id: nodeID),
            ascendants: [.init(
                id: runtimeID,
                name: "Recovery fixture",
                defaultTimelineID: configuredTimelineID,
                backend: .init(
                    kind: ACPAscendantBackend.kind,
                    settings: try fixtureSettings(stateHome: stateHome.url)
                )
            )],
            timelines: [.init(
                id: configuredTimelineID,
                title: "Configured",
                operatingAscendantID: runtimeID
            )]
        )
        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.registerBackend(
            kind: ACPAscendantBackend.kind,
            settings: ACPAscendantBackend.settingsSchema
        ) { ascendant, configuration, services, timelines in
            try ACPAscendantBackend(
                ascendant: ascendant,
                configuration: configuration,
                services: services,
                timelines: timelines
            )
        }
        let journalDirectory = stateHome.url.appendingPathComponent("timeline-journals", isDirectory: true)
        let firstRuntime = try await NodeRuntime(
            plan: manifest.compileLaunchPlan(),
            adapters: adapters,
            timelineJournalDirectory: journalDirectory
        )
        try await firstRuntime.start()
        defer { Task { @MainActor in await firstRuntime.shutdown() } }

        let created = try await firstRuntime.createTimeline(title: "Runtime Timeline", ascendantID: runtimeID)
        _ = try await firstRuntime.turn(.init(
            message: "persist a Runtime Session",
            timelineID: created.timelineID,
            clientTurnID: "runtime-session"
        ))
        await firstRuntime.shutdown()

        try FileManager.default.removeItem(at: stateHome.url.appendingPathComponent("agent-sessions.json"))
        let restartedRuntime = try await NodeRuntime(
            plan: manifest.compileLaunchPlan(),
            adapters: adapters,
            timelineJournalDirectory: journalDirectory
        )
        defer { Task { @MainActor in await restartedRuntime.shutdown() } }

        try await restartedRuntime.start()
        let snapshot = await restartedRuntime.snapshot()
        #expect(snapshot.timelineIDs.contains(configuredTimelineID))
        #expect(snapshot.timelineIDs.contains(created.timelineID))
        #expect(await restartedRuntime.timeline(id: created.timelineID)?.title == "Runtime Timeline")
        await restartedRuntime.shutdown()
    }

    @Test("configuration maps command, JSON args/env, cwd, and display name to a launch spec")
    @MainActor
    func configurationBuildsLaunchSpec() throws {
        let backend = try backend(settings: [
            "command": .string("opencode"),
            "args": .string("[\"acp\",\"--verbose\"]"),
            "cwd": .string("/workspace/project"),
            "env": .string("{\"MODE\":\"safe\",\"TOKEN_HINT\":\"not-secret\"}"),
            "displayName": .string("OpenCode"),
        ])

        #expect(backend.launchSpec.command == "opencode")
        #expect(backend.launchSpec.arguments == ["acp", "--verbose"])
        #expect(backend.launchSpec.workingDirectory == "/workspace/project")
        #expect(backend.launchSpec.environment == ["MODE": "safe", "TOKEN_HINT": "not-secret"])
        #expect(backend.launchSpec.displayName == "OpenCode")
    }

    @Test("ACP initialize retains unknown capability fields verbatim")
    func initializeCapabilitiesPreserveUnknownFields() throws {
        let source = #"{"protocolVersion":2,"info":{"name":"future-agent","version":"1"},"capabilities":{"session":{"mcp":{"http":{},"futureTransport":{"mode":"safe"}},"futureSession":{"enabled":true}},"futureCapability":{"values":[1,"two",true]}}}"#
        let response = try JSONDecoder().decode(ACPInitializeResponse.self, from: Data(source.utf8))
        let originalValue = try JSONDecoder().decode(ACPValue.self, from: Data(source.utf8))

        #expect(response.rawCapabilities == originalValue["capabilities"]?.objectValue)
    }

    @Test("Runtime refuses an ACP initialize response that negotiates another version")
    @MainActor
    func initializeRejectsNonV2ProtocolVersion() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let backend = try backend(
            settings: fixtureSettings(
                stateHome: stateHome.url,
                initializeProtocolVersion: ACPv2Protocol.protocolVersion - 1
            ),
            timelines: [.init(id: timelineID, title: "Wrong protocol version")]
        )

        do {
            _ = try await backend.operatedTimelines()
            Issue.record("The ACP Runtime with a mismatched protocol version was accepted.")
        } catch let AscendantBackendError.lifecycleUnusable(failure) {
            #expect(failure.code == "acpProtocolVersionMismatch")
            #expect(failure.message.contains(String(ACPv2Protocol.protocolVersion)))
        }
        await backend.shutdown()
    }

    @Test("Runtime identity excludes environment values but includes configured names")
    @MainActor
    func launchFingerprintUsesEnvironmentNamesOnly() throws {
        let first = try backend(settings: [
            "command": .string("/usr/bin/node"),
            "args": .string("[\"agent.mjs\"]"),
            "env.API_TOKEN": .string("first-secret"),
        ])
        let sameConfiguration = try backend(settings: [
            "command": .string("/usr/bin/node"),
            "args": .string("[\"agent.mjs\"]"),
            "env.API_TOKEN": .string("second-secret"),
        ])
        let differentEnvironmentNames = try backend(settings: [
            "command": .string("/usr/bin/node"),
            "args": .string("[\"agent.mjs\"]"),
            "env.OTHER_TOKEN": .string("first-secret"),
        ])
        let differentCommand = try backend(settings: [
            "command": .string("/usr/bin/python3"),
            "args": .string("[\"agent.mjs\"]"),
            "env.API_TOKEN": .string("first-secret"),
        ])
        let differentArguments = try backend(settings: [
            "command": .string("/usr/bin/node"),
            "args": .string("[\"agent.mjs\",\"--alternate\"]"),
            "env.API_TOKEN": .string("first-secret"),
        ])

        #expect(first.launchSpec.launchFingerprint == sameConfiguration.launchSpec.launchFingerprint)
        #expect(first.launchSpec.launchFingerprint != differentEnvironmentNames.launchSpec.launchFingerprint)
        #expect(first.launchSpec.launchFingerprint != differentCommand.launchSpec.launchFingerprint)
        #expect(first.launchSpec.launchFingerprint != differentArguments.launchSpec.launchFingerprint)
        #expect(!first.launchSpec.launchFingerprint.contains("first-secret"))
        #expect(!first.launchSpec.launchFingerprint.contains("API_TOKEN"))
    }

    @Test("Runtime instance snapshot reports initialized metadata and raw capabilities")
    @MainActor
    func runtimeInstanceSnapshotReportsInitializeMetadata() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let backend = try backend(
            settings: fixtureSettings(
                stateHome: stateHome.url,
                initializeExtraCapabilities: #"{"futureCapability":{"values":[1,"two"]},"session":{"futureSession":{"enabled":true}}}"#
            ),
            timelines: [.init(id: timelineID, title: "Runtime discovery")]
        )

        _ = try await backend.operatedTimelines()

        let instance = try #require(backend.runtimeInstanceObject)
        #expect(instance.runtimeID == backend.identity.id)
        #expect(instance.runtimeKind == "local-command")
        #expect(instance.runtimeVersion == "1")
        #expect(instance.launchFingerprint == backend.launchSpec.launchFingerprint)
        #expect(instance.rawCapabilities["futureCapability"] == .object(["values": .array([.int(1), .string("two")])]))
        #expect(instance.rawCapabilities["session"]?["futureSession"] == .object(["enabled": .bool(true)]))
        let serialized = try JSONEncoder().encode(instance)
        let decoded = try JSONDecoder().decode(GnosticRuntimeInstanceObject.self, from: serialized)
        #expect(decoded.launchFingerprint == instance.launchFingerprint)
        #expect(decoded.rawCapabilities == instance.rawCapabilities)
        await backend.shutdown()
    }

    @Test("a failed permission journal write prevents Workspace tool invocation")
    @MainActor
    func gatewayPermissionJournalFailurePreventsInvocation() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let runtimeID = UUID()
        let workspaceID = UUID()
        let store = TimelineJournalStore(directoryURL: stateHome.url.appendingPathComponent("journals"))
        let journal = try await store.journal(for: timelineID)
        let updates = AscendantTurnUpdateStore(timelineJournals: store)
        let permission = AscendantPermissionCoordinator(updates: updates)
        let workspace = GatewayWorkspaceService(workspaceReference: BackendWorkspaceReference(
            id: workspaceID, uri: "workspace://journal-fault", status: .available,
            tools: [.init(id: "write", name: "Write", description: "Write", parametersSchema: .object([:]), requiresPermission: true)]
        ))
        let registry = AscendantTimelineRegistry(
            ascendantID: runtimeID, privateTimelineID: timelineID,
            configured: [.init(id: timelineID, title: "Gateway", operatingAscendantID: runtimeID, attachments: [.local(workspaceID)])],
            remote: .init(ensure: { _, _ in }, rename: { _, _ in }, delete: { _ in })
        )
        let gateway = WorkspaceMCPGateway(
            timelineID: timelineID, timelineRegistry: registry, workspaceService: workspace,
            permissionService: permission, activeTurn: { _ in ("gateway-turn", "session") }
        )
        guard case let .http(_, endpoint, headers, _) = try gateway.start(),
              let url = URL(string: endpoint), let token = headers?.first(where: { $0.name == "Authorization" })?.value else {
            Issue.record("Missing gateway endpoint"); return
        }
        defer { gateway.stop() }
        let tool = "workspace_\(workspaceID.uuidString.lowercased().replacingOccurrences(of: "-", with: ""))__write"
        let call = Task { try await mcpRequest(url: url, authorization: token, method: "tools/call", params: ["name": .string(tool)]) }
        for _ in 0..<100 {
            if (try? await updates.replay(timelineID: timelineID, clientTurnID: "gateway-turn").updates.contains {
                $0.permissionState?.status == "pending"
            }) == true { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let replay = try await updates.replay(timelineID: timelineID, clientTurnID: "gateway-turn")
        let correlation = try #require(replay.updates.compactMap(\.permissionState?.correlationID).first)
        let journalURL = await journal.fileURL
        try FileManager.default.removeItem(at: journalURL)
        try FileManager.default.createDirectory(at: journalURL, withIntermediateDirectories: false)
        #expect(!(await permission.respond(correlationID: correlation, timelineID: timelineID, clientTurnID: "gateway-turn", approved: true)))
        let response = try await call.value
        #expect(response.message?.error != nil)
        #expect(workspace.invocations.isEmpty)
        #expect(try await updates.replay(timelineID: timelineID, clientTurnID: "gateway-turn").updates.allSatisfy { $0.permissionState?.status != "selected" })
    }

    @Test("MCP gateway lists attached tools and rechecks status before each call")
    @MainActor
    func mcpGatewayRechecksStatusAtInvocation() async throws {
        let ascendantID = UUID()
        let timelineID = UUID()
        let workspaceID = UUID()
        let tool = BackendWorkspaceTool(
            id: "search",
            name: "Search",
            description: "Search workspace records",
            parametersSchema: .object(["type": .string("object"), "properties": .object(["query": .object(["type": .string("string")])])]),
            requiresPermission: true
        )
        let workspaceService = GatewayWorkspaceService(workspaceReference: BackendWorkspaceReference(
            id: workspaceID,
            uri: "workspace://gateway-test",
            status: .available,
            tools: [tool]
        ))
        let timelineRegistry = AscendantTimelineRegistry(
            ascendantID: ascendantID,
            privateTimelineID: timelineID,
            configured: [.init(
                id: timelineID,
                title: "Gateway test",
                operatingAscendantID: ascendantID,
                attachments: [.local(workspaceID)]
            )],
            remote: .init(ensure: { _, _ in }, rename: { _, _ in }, delete: { _ in })
        )
        let permission = RecordingPermissionService(decision: .approved)
        let gateway = WorkspaceMCPGateway(
            timelineID: timelineID,
            timelineRegistry: timelineRegistry,
            workspaceService: workspaceService,
            permissionService: permission,
            activeTurn: { _ in ("turn-1", "session-1") }
        )
        guard case let .http(_, endpoint, headers, _ ) = try gateway.start(),
              let endpointURL = URL(string: endpoint),
              let token = headers?.first(where: { $0.name == "Authorization" })?.value else {
            Issue.record("The gateway must return an authenticated HTTP MCP endpoint.")
            return
        }
        defer { gateway.stop() }

        let listResponse = try await mcpRequest(
            url: endpointURL,
            authorization: token,
            method: "tools/list",
            params: [:]
        )
        #expect(listResponse.response.statusCode == 200)
        guard case let .object(listResult)? = listResponse.message?.result,
              case let .array(listedTools)? = listResult["tools"],
              case let .object(listedTool)? = listedTools.first,
              case let .string(toolName)? = listedTool["name"] else {
            Issue.record("tools/list must return the attached Workspace tool.")
            return
        }

        let missingAuthorization = try await mcpRequest(
            url: endpointURL,
            authorization: nil,
            method: "tools/list",
            params: [:]
        )
        #expect(missingAuthorization.response.statusCode == 401)

        let unattachedWorkspaceID = UUID()
        let unattachedCall = try await mcpRequest(
            url: endpointURL,
            authorization: token,
            method: "tools/call",
            params: ["name": .string("workspace_\(unattachedWorkspaceID.uuidString.lowercased().replacingOccurrences(of: "-", with: ""))__search"), "arguments": .object([:])]
        )
        #expect(unattachedCall.message?.error?.code == -32003)
        #expect(workspaceService.invocations.isEmpty)

        let successfulCall = try await mcpRequest(
            url: endpointURL,
            authorization: token,
            method: "tools/call",
            params: ["name": .string(toolName), "arguments": .object(["query": .string("needle")])]
        )
        #expect(successfulCall.response.statusCode == 200)
        #expect(successfulCall.message?.error == nil)
        #expect(workspaceService.invocations == [BackendWorkspaceInvocation(
            timelineID: timelineID,
            permissionApproved: true,
            workspaceID: workspaceID,
            toolID: "search",
            arguments: ["query": .string("needle")]
        )])
        #expect(await permission.requests.count == 1)

        timelineRegistry.detachWorkspace(workspaceID, from: timelineID)
        let detachedCall = try await mcpRequest(
            url: endpointURL,
            authorization: token,
            method: "tools/call",
            params: ["name": .string(toolName), "arguments": .object([:])]
        )
        #expect(detachedCall.message?.error?.code == -32003)
        #expect(workspaceService.invocations.count == 1)
        try timelineRegistry.attachWorkspace(workspaceID, to: timelineID)

        workspaceService.workspaceReference = BackendWorkspaceReference(
            id: workspaceID,
            uri: "workspace://gateway-test",
            status: .unavailable,
            tools: [tool]
        )
        let staleCall = try await mcpRequest(
            url: endpointURL,
            authorization: token,
            method: "tools/call",
            params: ["name": .string(toolName), "arguments": .object([:])]
        )
        #expect(staleCall.response.statusCode == 200)
        #expect(staleCall.message?.error?.code == -32003)
        #expect(workspaceService.invocations.count == 1)
    }

    @Test(
        "standalone Positronic Runtime calls the live Gnostic MCP gateway across processes",
        .timeLimit(.minutes(1)),
        .enabled(if: ProcessInfo.processInfo.environment["GNOSTIC_PK_RUNTIME_BINARY"] != nil,
                 "GNOSTIC_PK_RUNTIME_BINARY is not set")
    )
    @MainActor
    func standaloneRuntimeCallsGnosticGateway() async throws {
        let runtimeBinary = try #require(ProcessInfo.processInfo.environment["GNOSTIC_PK_RUNTIME_BINARY"])
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }

        let ascendantID = UUID()
        let timelineID = UUID()
        let workspaceID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000609"))
        let workspaceService = GatewayWorkspaceService(workspaceReference: BackendWorkspaceReference(
            id: workspaceID,
            uri: "workspace://standalone-runtime-integration",
            status: .available,
            tools: [BackendWorkspaceTool(
                id: "search",
                name: "Search",
                description: "Search records",
                parametersSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["query": .object(["type": .string("string")])]),
                ])
            )]
        ))
        let timelineRegistry = AscendantTimelineRegistry(
            ascendantID: ascendantID,
            privateTimelineID: timelineID,
            configured: [.init(
                id: timelineID,
                title: "Standalone Runtime integration",
                operatingAscendantID: ascendantID,
                attachments: [.local(workspaceID)]
            )],
            remote: .init(ensure: { _, _ in }, rename: { _, _ in }, delete: { _ in })
        )
        let gateway = WorkspaceMCPGateway(
            timelineID: timelineID,
            timelineRegistry: timelineRegistry,
            workspaceService: workspaceService,
            permissionService: AscendantBackendServices.empty.permission,
            activeTurn: { _ in nil }
        )
        let mcpServer = try gateway.start()
        defer { gateway.stop() }

        let toolName = "workspace_\(workspaceID.uuidString.lowercased().replacingOccurrences(of: "-", with: ""))__search"
        let runtimeStateDirectory = stateHome.url.appendingPathComponent("runtime-state", isDirectory: true)
        let client = try RuntimeACPSubprocessClient(
            executableURL: URL(fileURLWithPath: runtimeBinary),
            environment: [
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                "HOME": ProcessInfo.processInfo.environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
                "GNOSTIC_PK_SCRIPTED": "1",
                "GNOSTIC_PK_STATE_DIR": runtimeStateDirectory.path,
                "GNOSTIC_PK_FIXTURE_TOOL_NAME": toolName,
            ]
        )
        defer { Task { await client.terminate() } }

        try await client.send(ACPJSONRPCRequest(
            id: .int(1),
            method: ACPv2Protocol.AgentMethod.initialize,
            params: try acpValue(ACPInitializeRequest(info: ACPImplementation(name: "Gnostic gateway test", version: "1")))
        ))
        let initialized = try await client.response(id: 1)
        #expect(initialized.error == nil)

        try await client.send(ACPJSONRPCRequest(
            id: .int(2),
            method: ACPv2Protocol.AgentMethod.sessionNew,
            params: try acpValue(ACPNewSessionRequest(cwd: "/tmp", mcpServers: [mcpServer]))
        ))
        let created = try await client.response(id: 2)
        let session = try decode(ACPNewSessionResponse.self, from: #require(created.result))

        try await client.send(ACPJSONRPCRequest(
            id: .int(3),
            method: ACPv2Protocol.AgentMethod.sessionPrompt,
            params: try acpValue(ACPPromptRequest(
                sessionId: session.sessionId,
                prompt: [.text(ACPTextContent(text: "[fixture:gateway-tool]"))]
            ))
        ))
        let prompted = try await client.response(id: 3)
        #expect(prompted.error == nil)

        var assistantText = ""
        var becameIdle = false
        while !becameIdle {
            let notification = try await client.notification()
            #expect(notification.method == ACPv2Protocol.ClientMethod.sessionUpdate)
            let update = try decode(ACPSessionNotification.self, from: #require(notification.params))
            #expect(update.sessionId == session.sessionId)
            switch update.update {
            case let .agentMessageChunk(chunk):
                if case let .text(text) = chunk.content { assistantText += text.text }
            case let .stateUpdate(state):
                becameIdle = state.isIdle
            default:
                break
            }
        }

        #expect(assistantText.contains("workspace result"))
        #expect(workspaceService.invocations == [BackendWorkspaceInvocation(
            timelineID: timelineID,
            permissionApproved: false,
            workspaceID: workspaceID,
            toolID: "search",
            arguments: ["query": .string("fixture")]
        )])

        try await client.send(ACPJSONRPCRequest(
            id: .int(4),
            method: ACPv2Protocol.AgentMethod.sessionClose,
            params: try acpValue(ACPCloseSessionRequest(sessionId: session.sessionId))
        ))
        let closed = try await client.response(id: 4)
        #expect(closed.error == nil)
        await client.finish()
    }

    @Test("ACP sessions receive the live MCP gateway for attached Workspaces")
    @MainActor
    func acpSessionInvokesAttachedWorkspaceThroughMCP() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let workspaceID = UUID()
        let definition = BackendWorkspaceTool(id: "search", name: "Search", description: "Search records")
        let workspaceService = GatewayWorkspaceService(workspaceReference: BackendWorkspaceReference(
            id: workspaceID,
            uri: "workspace://mcp-integration",
            status: .available,
            tools: [definition]
        ))
        let timeline = NodeManifest.Timeline(
            id: timelineID,
            title: "Workspace MCP",
            attachments: [.local(workspaceID)]
        )
        let backend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url, mcpGateway: true),
            timelines: [timeline],
            workspace: workspaceService
        )
        defer { Task { await backend.shutdown() } }

        _ = try await backend.runTurn(
            .init(timelineID: timelineID, message: "[fixture:workspace-tool]"),
            updates: RecordingUpdateSink()
        )

        #expect(workspaceService.invocations.count == 1)
        #expect(workspaceService.invocations.first?.workspaceID == workspaceID)
        #expect(workspaceService.invocations.first?.toolID == "search")

        let localProject = stateHome.url.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: localProject, withIntermediateDirectories: false)
        try await backend.setProject(.local(localProject.path), for: timelineID)
        _ = try await backend.runTurn(
            .init(timelineID: timelineID, message: "[fixture:workspace-tool]"),
            updates: RecordingUpdateSink()
        )
        #expect(workspaceService.invocations.count == 2)
    }

    @Test("an active ACP Session sees Workspace attachments added and removed at runtime")
    @MainActor
    func acpSessionReflectsRuntimeWorkspaceAttachmentChanges() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let workspaceID = UUID()
        let definition = BackendWorkspaceTool(id: "search", name: "Search", description: "Search records")
        let reference = BackendWorkspaceReference(
            id: workspaceID,
            uri: "workspace://dynamic-mcp",
            status: .available,
            tools: [definition]
        )
        let workspaceService = GatewayWorkspaceService(workspaceReference: reference)
        let timeline = NodeManifest.Timeline(id: timelineID, title: "Dynamic Workspace")
        let backend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url, mcpGateway: true),
            timelines: [timeline],
            workspace: workspaceService
        )
        defer { Task { await backend.shutdown() } }

        _ = try await backend.runTurn(.init(timelineID: timelineID, message: "start"), updates: RecordingUpdateSink())
        let workspaceCapability = try backend.requireCapability(.workspace, as: (any AscendantBackendWorkspaceCapability).self)
        try await workspaceCapability.attachWorkspace(reference, to: timelineID)
        _ = try await backend.runTurn(
            .init(timelineID: timelineID, message: "[fixture:workspace-tool]"),
            updates: RecordingUpdateSink()
        )
        #expect(workspaceService.invocations.count == 1)

        try await workspaceCapability.detachWorkspace(workspaceID, from: timelineID)
        _ = try await backend.runTurn(
            .init(timelineID: timelineID, message: "[fixture:workspace-tool-empty]"),
            updates: RecordingUpdateSink()
        )
        #expect(workspaceService.invocations.count == 1)
    }

    @MainActor
    private func mcpRequest(
        url: URL,
        authorization: String?,
        method: String,
        params: [String: ACPValue]
    ) async throws -> (response: HTTPURLResponse, message: ACPJSONRPCResponse?) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if method != "initialize" { request.setValue("2025-03-26", forHTTPHeaderField: "MCP-Protocol-Version") }
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(ACPJSONRPCRequest(id: .string("test"), method: method, params: .object(params)))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (httpResponse, try? JSONDecoder().decode(ACPJSONRPCResponse.self, from: data))
    }

    private func acpValue<T: Encodable>(_ value: T) throws -> ACPValue {
        try JSONDecoder().decode(ACPValue.self, from: JSONEncoder().encode(value))
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: ACPValue) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }

    @Test("local Project cwd is passed to ACP session/new")
    @MainActor
    func localProjectCWDIsUsedForSession() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let projectURL = stateHome.url.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: false)
        let timelineID = UUID()
        let timeline = NodeManifest.Timeline(
            id: timelineID,
            title: "Local repository",
            project: .local(projectURL.path)
        )
        let backend = try fixtureBackend(timelines: [timeline], stateHome: stateHome.url)
        defer { Task { await backend.shutdown() } }

        _ = try await backend.runTurn(.init(timelineID: timelineID, message: "inspect repository"), updates: RecordingUpdateSink())
        let binding = try #require(backend.sessionBinding(for: timelineID))
        #expect(binding.timelineID == timelineID)
        #expect(binding.projectKind == .local)
        #expect(binding.cwd == projectURL.standardizedFileURL.path)
        #expect(!binding.contextContinuityGuaranteed)

        let remoteData = try Data(contentsOf: stateHome.url.appendingPathComponent("agent-sessions.json"))
        let remoteSessions = try #require(JSONSerialization.jsonObject(with: remoteData) as? [String: [String: String]])
        #expect(remoteSessions[binding.sessionID]?["cwd"] == projectURL.standardizedFileURL.path)
        await backend.shutdown()
    }

    @Test("scratch Project is isolated and a cwd transition opens a new Session on the same Timeline")
    @MainActor
    func scratchProjectTransitionsToLocalSession() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let scratchRoot = stateHome.url.appendingPathComponent("scratch", isDirectory: true)
        let projectURL = stateHome.url.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: false)
        let timelineID = UUID()
        let timeline = NodeManifest.Timeline(id: timelineID, title: "Transition", project: .scratch)
        var settings = try fixtureSettings(stateHome: stateHome.url)
        settings["scratchRoot"] = .string(scratchRoot.path)
        let backend = try backend(settings: settings, timelines: [timeline])
        defer { Task { await backend.shutdown() } }

        _ = try await backend.runTurn(.init(timelineID: timelineID, message: "start in scratch"), updates: RecordingUpdateSink())
        let scratchBinding = try #require(backend.sessionBinding(for: timelineID))
        #expect(scratchBinding.projectKind == .scratch)
        #expect(FileManager.default.fileExists(atPath: scratchBinding.cwd))
        #expect(scratchBinding.cwd.hasPrefix(scratchRoot.path + "/"))

        try await backend.setProject(.local(projectURL.path), for: timelineID)
        #expect(backend.sessionBinding(for: timelineID) == nil)
        #expect(!FileManager.default.fileExists(atPath: scratchBinding.cwd))

        _ = try await backend.runTurn(.init(timelineID: timelineID, message: "continue in checkout"), updates: RecordingUpdateSink())
        let localBinding = try #require(backend.sessionBinding(for: timelineID))
        #expect(localBinding.timelineID == timelineID)
        #expect(localBinding.projectKind == .local)
        #expect(localBinding.cwd == projectURL.standardizedFileURL.path)
        #expect(localBinding.sessionID != scratchBinding.sessionID)
        #expect(!localBinding.contextContinuityGuaranteed)
        await backend.shutdown()
    }

    @Test("changing a configured Project cwd across restart replaces the Session on the same Timeline")
    @MainActor
    func configuredProjectCWDChangeCreatesSessionAfterRestart() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let firstDirectory = stateHome.url.appendingPathComponent("first", isDirectory: true)
        let nextDirectory = stateHome.url.appendingPathComponent("next", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: nextDirectory, withIntermediateDirectories: false)
        let timelineID = UUID()
        let ascendantID = UUID()
        let firstTimeline = NodeManifest.Timeline(id: timelineID, title: "Restart", project: .local(firstDirectory.path))
        let firstBackend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url),
            timelines: [firstTimeline],
            ascendantID: ascendantID
        )
        _ = try await firstBackend.runTurn(.init(timelineID: timelineID, message: "before change"), updates: RecordingUpdateSink())
        let previousBinding = try #require(firstBackend.sessionBinding(for: timelineID))
        await firstBackend.shutdown()

        let nextTimeline = NodeManifest.Timeline(id: timelineID, title: "Restart", project: .local(nextDirectory.path))
        let nextBackend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url),
            timelines: [nextTimeline],
            ascendantID: ascendantID
        )
        _ = try await nextBackend.operatedTimelines()
        let nextBinding = try #require(nextBackend.sessionBinding(for: timelineID))
        #expect(nextBinding.timelineID == timelineID)
        #expect(nextBinding.startedAt != previousBinding.startedAt)
        #expect(nextBinding.cwd == nextDirectory.standardizedFileURL.path)
        #expect(nextBinding.projectKind == .local)
        await nextBackend.shutdown()
    }

    @Test("journal recovery respects a changed configured Project")
    @MainActor
    func journalRecoveryRespectsConfiguredProject() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let first = stateHome.url.appendingPathComponent("first")
        let next = stateHome.url.appendingPathComponent("next")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        let timelineID = UUID()
        let runtimeID = UUID()
        let configuration = AscendantBackendConfiguration(
            kind: ACPAscendantBackend.kind, settings: try fixtureSettings(stateHome: stateHome.url)
        )
        var manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "project-journal-\(UUID().uuidString)"),
            node: .init(id: UUID()),
            ascendants: [.init(id: runtimeID, name: "Project fixture", defaultTimelineID: timelineID, backend: configuration)],
            timelines: [.init(id: timelineID, title: "Project", operatingAscendantID: runtimeID, project: .local(first.path))]
        )
        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.registerBackend(kind: ACPAscendantBackend.kind, settings: ACPAscendantBackend.settingsSchema) {
            ascendant, configuration, services, timelines in
            try ACPAscendantBackend(ascendant: ascendant, configuration: configuration, services: services, timelines: timelines)
        }
        let directory = stateHome.url.appendingPathComponent("journals")
        let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan(), adapters: adapters, timelineJournalDirectory: directory)
        try await runtime.start()
        _ = try await runtime.turn(.init(message: "first", timelineID: timelineID, clientTurnID: "first"))
        await runtime.shutdown()
        manifest.timelines[0].project = .local(next.path)
        let restarted = try await NodeRuntime(plan: manifest.compileLaunchPlan(), adapters: adapters, timelineJournalDirectory: directory)
        try await restarted.start()
        _ = try await restarted.turn(.init(message: "next", timelineID: timelineID, clientTurnID: "next"))
        await restarted.shutdown()
        let store = TimelineJournalStore(directoryURL: directory.appendingPathComponent(manifest.node.id.uuidString.lowercased()))
        let projection = try #require(try await store.timelineProjection(for: timelineID))
        #expect(projection.latestSession?.cwd == next.standardizedFileURL.path)
    }

    @Test("a Project change retires the journal binding before the next Turn")
    @MainActor
    func projectChangeRetiresJournalBinding() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let runtimeID = UUID()
        let store = TimelineJournalStore(directoryURL: stateHome.url.appendingPathComponent("journals"))
        try await store.ensureTimelineCreated(timelineID: timelineID, title: "Project", runtimeInstanceID: runtimeID, attachments: [])
        let timeline = NodeManifest.Timeline(id: timelineID, title: "Project")
        let instance = try backend(
            settings: fixtureSettings(stateHome: stateHome.url), timelines: [timeline], ascendantID: runtimeID,
            optionalCapabilities: [TimelineJournalRecorder(journals: store)]
        )
        _ = try await instance.runTurn(.init(timelineID: timelineID, message: "first", clientTurnID: "first"), updates: RecordingUpdateSink())
        #expect(try await store.timelineProjection(for: timelineID)?.latestSession != nil)
        let next = stateHome.url.appendingPathComponent("next")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        try await instance.setProject(.local(next.path), for: timelineID)
        #expect(try await store.timelineProjection(for: timelineID)?.latestSession == nil)
        #expect(try await store.timelineProjection(for: timelineID)?.project == .local(next.path))
        await instance.shutdown()
        let restarted = try backend(
            settings: fixtureSettings(stateHome: stateHome.url), timelines: [timeline], ascendantID: runtimeID,
            optionalCapabilities: [TimelineJournalRecorder(journals: store)]
        )
        _ = try await restarted.operatedTimelines()
        #expect(restarted.sessionBinding(for: timelineID)?.cwd == next.standardizedFileURL.path)
        await restarted.shutdown()
    }

    @Test("an update adjacent to a new Session response is committed after its binding", arguments: ["before", "after"])
    @MainActor
    func immediateSessionUpdateWaitsForBinding(_ order: String) async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let runtimeID = UUID()
        let store = TimelineJournalStore(directoryURL: stateHome.url.appendingPathComponent("journals"))
        try await store.ensureTimelineCreated(timelineID: timelineID, title: "Immediate", runtimeInstanceID: runtimeID, attachments: [])
        var settings = try fixtureSettings(stateHome: stateHome.url)
        settings["env.GNOSTIC_ACP_FIXTURE_ADJACENT_SESSION_UPDATE"] = .string(order)
        let instance = try backend(
            settings: settings, timelines: [.init(id: timelineID, title: "Immediate")], ascendantID: runtimeID,
            optionalCapabilities: [TimelineJournalRecorder(journals: store)]
        )
        _ = try await instance.operatedTimelines()
        let journal = try await store.journal(for: timelineID)
        let records = try await journal.replay()
        let transition = try #require(records.firstIndex { if case .sessionTransition = $0.payload { return true }; return false })
        let update = try #require(records.firstIndex {
            if case let .rawACPUpdate(_, _, update) = $0.payload,
               case .other(sessionUpdate: "fixture_session_opened", fields: _) = update { return true }
            return false
        })
        #expect(transition < update)
        _ = try await instance.runTurn(.init(timelineID: timelineID, message: "still healthy", clientTurnID: "healthy"), updates: RecordingUpdateSink())
        await instance.shutdown()
    }

    @Test("Timeline journal restores the ACP Session when the backend session map is missing")
    @MainActor
    func journalRestoresSessionWithoutBackendMap() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let ascendantID = UUID()
        let timeline = NodeManifest.Timeline(id: timelineID, title: "Journal recovery")
        let firstBackend = try fixtureBackend(
            timelines: [timeline],
            ascendantID: ascendantID,
            stateHome: stateHome.url
        )
        _ = try await firstBackend.runTurn(
            .init(timelineID: timelineID, message: "before restart"),
            updates: RecordingUpdateSink()
        )
        let previousBinding = try #require(firstBackend.sessionBinding(for: timelineID))
        await firstBackend.shutdown()

        let journalStore = TimelineJournalStore(directoryURL: stateHome.url.appendingPathComponent("timeline-journals"))
        try await journalStore.ensureTimelineCreated(
            timelineID: timelineID,
            title: timeline.title,
            runtimeInstanceID: ascendantID,
            attachments: []
        )
        let journal = try await journalStore.journal(for: timelineID)
        try await journal.append(.sessionTransition(
            sessionID: previousBinding.sessionID,
            runtimeInstanceID: ascendantID,
            state: .live,
            projectKind: previousBinding.projectKind,
            cwd: previousBinding.cwd
        ))
        let journalRecorder = TimelineJournalRecorder(journals: journalStore)
        let journalSession = try #require(try await journalRecorder.sessionProjection(for: timelineID))

        let sessionMapURL = stateHome.url.appendingPathComponent("\(ascendantID.uuidString).json")
        try FileManager.default.removeItem(at: sessionMapURL)
        let restartedBackend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url),
            timelines: [timeline],
            ascendantID: ascendantID,
            optionalCapabilities: [journalRecorder]
        )
        defer { Task { await restartedBackend.shutdown() } }

        _ = try await restartedBackend.operatedTimelines()
        let recoveredBinding = try #require(restartedBackend.sessionBinding(for: timelineID))
        #expect(recoveredBinding.sessionID == previousBinding.sessionID)
        #expect(recoveredBinding.cwd == previousBinding.cwd)
        #expect(recoveredBinding.startedAt == journalSession.startedAt)
        await restartedBackend.shutdown()
    }

    @Test("a restored ACP Session resumes with its original Runtime, session ID, and cwd")
    @MainActor
    func restoredSessionResumesNativelyWithOriginalIdentity() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let runtimeID = UUID()
        let timeline = NodeManifest.Timeline(id: timelineID, title: "Native resume")
        let store = TimelineJournalStore(directoryURL: stateHome.url.appendingPathComponent("journals"))
        try await store.ensureTimelineCreated(timelineID: timelineID, title: timeline.title, runtimeInstanceID: runtimeID, attachments: [])
        let resumeRequests = stateHome.url.appendingPathComponent("resume-requests.jsonl")
        let newSessions = stateHome.url.appendingPathComponent("new-sessions.txt")
        let prompts = stateHome.url.appendingPathComponent("prompts.txt")
        var settings = try fixtureSettings(stateHome: stateHome.url)
        settings["env.GNOSTIC_ACP_FIXTURE_RESUME_REQUEST_FILE"] = .string(resumeRequests.path)
        settings["env.GNOSTIC_ACP_FIXTURE_NEW_SESSION_FILE"] = .string(newSessions.path)
        settings["env.GNOSTIC_ACP_FIXTURE_PROMPT_REQUEST_FILE"] = .string(prompts.path)
        let recorder = TimelineJournalRecorder(journals: store)
        let firstBackend = try backend(settings: settings, timelines: [timeline], ascendantID: runtimeID, optionalCapabilities: [recorder])
        _ = try await firstBackend.runTurn(.init(timelineID: timelineID, message: "first", clientTurnID: "first"), updates: RecordingUpdateSink())
        let previous = try #require(firstBackend.sessionBinding(for: timelineID))
        await firstBackend.shutdown()

        let restartedBackend = try backend(settings: settings, timelines: [timeline], ascendantID: runtimeID, optionalCapabilities: [recorder])
        _ = try await restartedBackend.operatedTimelines()
        #expect(try await store.timelineProjection(for: timelineID)?.latestSession?.state == .live)
        _ = try await restartedBackend.runTurn(.init(timelineID: timelineID, message: "continue", clientTurnID: "continue"), updates: RecordingUpdateSink())
        await restartedBackend.shutdown()

        let requestData = try Data(contentsOf: resumeRequests)
        let request = try #require(try JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        #expect(request["sessionId"] as? String == previous.sessionID)
        #expect(request["cwd"] as? String == previous.cwd)
        #expect(try String(contentsOf: newSessions, encoding: .utf8).split(whereSeparator: \.isNewline).count == 1)
        #expect(try String(contentsOf: prompts, encoding: .utf8).split(whereSeparator: \.isNewline).count == 2)
        #expect(try await store.timelineProjection(for: timelineID)?.latestSession?.runtimeInstanceID == runtimeID)
        let transitions = try await store.journal(for: timelineID).replay().compactMap { record -> TimelineJournalSessionState? in
            guard case let .sessionTransition(sessionID, _, state, _, _) = record.payload,
                  sessionID == previous.sessionID else { return nil }
            return state
        }
        #expect(transitions.suffix(2) == [.ambiguous, .live])
    }

    @Test("a quarantined journal prevents native resume dispatch")
    @MainActor
    func quarantinedResumeJournalBlocksDispatch() async throws {
        let stateHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-acp-resume-journal-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stateHome) }
        let timelineID = UUID()
        let runtimeID = UUID()
        let timeline = NodeManifest.Timeline(
            id: timelineID,
            title: "Resume journal failure",
            project: .local(stateHome.path)
        )
        let journalDirectory = stateHome.appendingPathComponent("journals")
        let store = TimelineJournalStore(directoryURL: journalDirectory)
        try await store.ensureTimelineCreated(timelineID: timelineID, title: timeline.title, runtimeInstanceID: runtimeID, attachments: [])
        let recorder = TimelineJournalRecorder(journals: store)
        let sessionID = "journal-write-failure-session"
        try await recorder.appendSessionTransition(
            timelineID: timelineID,
            sessionID: sessionID,
            runtimeInstanceID: runtimeID,
            state: .live,
            projectKind: .local,
            cwd: stateHome.path
        )

        let resumeRequests = stateHome.appendingPathComponent("resume-requests.jsonl")
        let newSessions = stateHome.appendingPathComponent("new-sessions.txt")
        let prompts = stateHome.appendingPathComponent("prompts.txt")
        var settings = try fixtureSettings(stateHome: stateHome)
        settings["env.GNOSTIC_ACP_FIXTURE_RESUME_REQUEST_FILE"] = .string(resumeRequests.path)
        settings["env.GNOSTIC_ACP_FIXTURE_NEW_SESSION_FILE"] = .string(newSessions.path)
        settings["env.GNOSTIC_ACP_FIXTURE_PROMPT_REQUEST_FILE"] = .string(prompts.path)

        let journalURL = TimelineJournalStore.fileURL(for: timelineID, in: journalDirectory)
        let journalFile = try FileHandle(forWritingTo: journalURL)
        try journalFile.seekToEnd()
        try journalFile.write(contentsOf: Data("not-json\n".utf8))
        try journalFile.close()

        let reopenedStore = TimelineJournalStore(directoryURL: journalDirectory)
        let restartedBackend = try backend(
            settings: settings,
            timelines: [timeline],
            ascendantID: runtimeID,
            optionalCapabilities: [TimelineJournalRecorder(journals: reopenedStore)]
        )
        defer { Task { await restartedBackend.shutdown() } }
        _ = try await restartedBackend.operatedTimelines()
        #expect(restartedBackend.sessionBinding(for: timelineID)?.sessionID == sessionID)
        let reopenedJournal = try await reopenedStore.journal(for: timelineID)
        if case .quarantined = await reopenedJournal.status() {
            // The committed prefix still supplies the native Session binding.
        } else {
            Issue.record("the corrupt committed tail must quarantine the journal")
        }
        #expect(try await reopenedStore.timelineProjection(for: timelineID)?.latestSession?.state == .live)
        do {
            _ = try await restartedBackend.runTurn(
                .init(timelineID: timelineID, message: "journal write must block resume"),
                updates: RecordingUpdateSink()
            )
            Issue.record("a failed ambiguity journal append must prevent native resume")
        } catch let AscendantBackendError.terminal(failure) {
            #expect(failure.code == "acpAgentFailure")
            #expect(failure.message.contains("journal is read-only because it is quarantined"))
        } catch {
            Issue.record("expected the quarantined journal append to fail before ACP dispatch; got \(error)")
        }
        await restartedBackend.shutdown()
        #expect(!FileManager.default.fileExists(atPath: resumeRequests.path))
        #expect(!FileManager.default.fileExists(atPath: newSessions.path))
        #expect(!FileManager.default.fileExists(atPath: prompts.path))
    }

    @Test("a failed resume is durably ambiguous before dispatch and blocks Sessions and prompts across restart", arguments: ["transport", "server-error", "invalid-params"])
    @MainActor
    func uncertainResumeBlocksCreationAndPromptAfterRestart(_ failureKind: String) async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let runtimeID = UUID()
        let timeline = NodeManifest.Timeline(id: timelineID, title: "Uncertain resume")
        let journalDirectory = stateHome.url.appendingPathComponent("journals")
        let store = TimelineJournalStore(directoryURL: journalDirectory)
        try await store.ensureTimelineCreated(timelineID: timelineID, title: timeline.title, runtimeInstanceID: runtimeID, attachments: [])
        let resumeRequests = stateHome.url.appendingPathComponent("resume-requests.jsonl")
        let newSessions = stateHome.url.appendingPathComponent("new-sessions.txt")
        let prompts = stateHome.url.appendingPathComponent("prompts.txt")
        let ambiguousAtDispatch = stateHome.url.appendingPathComponent("ambiguous-at-dispatch.txt")
        let recorder = TimelineJournalRecorder(journals: store)
        var initialSettings = try fixtureSettings(stateHome: stateHome.url)
        initialSettings["env.GNOSTIC_ACP_FIXTURE_NEW_SESSION_FILE"] = .string(newSessions.path)
        initialSettings["env.GNOSTIC_ACP_FIXTURE_PROMPT_REQUEST_FILE"] = .string(prompts.path)
        let firstBackend = try backend(settings: initialSettings, timelines: [timeline], ascendantID: runtimeID, optionalCapabilities: [recorder])
        _ = try await firstBackend.runTurn(.init(timelineID: timelineID, message: "first", clientTurnID: "first"), updates: RecordingUpdateSink())
        let previous = try #require(firstBackend.sessionBinding(for: timelineID))
        await firstBackend.shutdown()

        var exitingSettings = try fixtureSettings(stateHome: stateHome.url)
        if failureKind == "transport" {
            exitingSettings["env.GNOSTIC_ACP_FIXTURE_EXIT_ON_RESUME"] = .string("1")
        } else if failureKind == "invalid-params" {
            exitingSettings["env.GNOSTIC_ACP_FIXTURE_REJECT_RESUME"] = .string("1")
        } else {
            exitingSettings["env.GNOSTIC_ACP_FIXTURE_INTERNAL_RESUME_ERROR"] = .string("1")
        }
        exitingSettings["env.GNOSTIC_ACP_FIXTURE_RESUME_REQUEST_FILE"] = .string(resumeRequests.path)
        exitingSettings["env.GNOSTIC_ACP_FIXTURE_ASSERT_AMBIGUOUS_JOURNAL_FILE"] = .string(ambiguousAtDispatch.path)
        exitingSettings["env.GNOSTIC_ACP_FIXTURE_TIMELINE_JOURNAL_FILE"] = .string(TimelineJournalStore.fileURL(for: timelineID, in: journalDirectory).path)
        exitingSettings["env.GNOSTIC_ACP_FIXTURE_NEW_SESSION_FILE"] = .string(newSessions.path)
        exitingSettings["env.GNOSTIC_ACP_FIXTURE_PROMPT_REQUEST_FILE"] = .string(prompts.path)
        let uncertainBackend = try backend(settings: exitingSettings, timelines: [timeline], ascendantID: runtimeID, optionalCapabilities: [recorder])
        _ = try await uncertainBackend.operatedTimelines()
        do {
            _ = try await uncertainBackend.runTurn(.init(timelineID: timelineID, message: "uncertain", clientTurnID: "uncertain"), updates: RecordingUpdateSink())
            Issue.record("an uncertain resume must fail closed")
        } catch { }
        await uncertainBackend.shutdown()
        #expect(try await recorder.sessionProjection(for: timelineID)?.state == .ambiguous)
        #expect(try String(contentsOf: ambiguousAtDispatch, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "ambiguous")

        let restartedBackend = try backend(settings: initialSettings, timelines: [timeline], ascendantID: runtimeID, optionalCapabilities: [recorder])
        _ = try await restartedBackend.operatedTimelines()
        do {
            _ = try await restartedBackend.runTurn(.init(timelineID: timelineID, message: "must remain blocked", clientTurnID: "blocked"), updates: RecordingUpdateSink())
            Issue.record("an ambiguous Session must stay blocked after restart")
        } catch { }
        await restartedBackend.shutdown()

        #expect(restartedBackend.sessionBinding(for: timelineID)?.sessionID == previous.sessionID)
        #expect(try String(contentsOf: newSessions, encoding: .utf8).split(whereSeparator: \.isNewline).count == 1)
        #expect(try String(contentsOf: prompts, encoding: .utf8).split(whereSeparator: \.isNewline).count == 1)
        #expect(try String(contentsOf: resumeRequests, encoding: .utf8).split(whereSeparator: \.isNewline).count == 1)
    }

    @Test("plain and secret per-variable values map to the launch environment")
    @MainActor
    func perVariableEnvironmentValuesAreCombined() throws {
        let backend = try backend(
            settings: [
                "command": .string("opencode"),
                "args": .string("[\"private-token\"]"),
                "env": .string("{\"MODE\":\"safe\"}"),
                "env.REGION": .string("test-west"),
            ],
            secrets: ["env-secret.API_TOKEN": .string("private-token")]
        )

        #expect(backend.launchSpec.environment == [
            "MODE": "safe",
            "REGION": "test-west",
            "API_TOKEN": "private-token",
        ])
        #expect(backend.launchSpec.description.contains("API_TOKEN"))
        #expect(!backend.launchSpec.description.contains("private-token"))
        #expect(!backend.launchSpec.debugDescription.contains("private-token"))
    }

    @Test("agent receives configured environment only, not unrelated parent credentials")
    @MainActor
    func processEnvironmentIsAllowlisted() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let key = "GNOSTIC_ACP_PARENT_ONLY_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let secret = "parent-secret-\(UUID().uuidString)"
        guard setenv(key, secret, 1) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { _ = unsetenv(key) }

        let backend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url, requiredAbsentEnvironmentKey: key),
            timelines: [.init(id: UUID(), title: "Allowlist")]
        )
        _ = try await backend.operatedTimelines()
        await backend.shutdown()
    }

    @Test("process spawn failure is lifecycle unusable and does not expose configured secrets")
    @MainActor
    func spawnFailureIsLifecycleUnusableAndRedacted() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let secret = "spawn-secret-\(UUID().uuidString)"
        let timelineID = UUID()
        let backend = try backend(
            settings: ["command": .string("/missing/acp-agent-\(UUID().uuidString)")],
            secrets: ["env-secret.API_TOKEN": .string(secret)],
            timelines: [.init(id: timelineID, title: "Missing agent")]
        )

        do {
            _ = try await backend.runTurn(.init(timelineID: timelineID, message: "hello"), updates: RecordingUpdateSink())
            Issue.record("Expected the missing ACP agent process to fail.")
        } catch let AscendantBackendError.lifecycleUnusable(failure) {
            #expect(!failure.message.contains(secret))
            #expect(!String(describing: failure).contains(secret))
        }
        await backend.shutdown()
    }

    @Test("invalid per-variable names and conflicting values are rejected without exposing secrets")
    @MainActor
    func invalidDynamicEnvironmentConfigurationIsRejected() {
        #expect(throws: (any Error).self) {
            try backend(settings: [
                "command": .string("opencode"),
                "env.bad-name": .string("invalid"),
            ])
        }
        #expect(throws: (any Error).self) {
            try backend(
                settings: ["command": .string("opencode"), "env.API_TOKEN": .string("plain")],
                secrets: ["env-secret.API_TOKEN": .string("private-token")]
            )
        }
        do {
            _ = try backend(secrets: ["unrelated.API_TOKEN": .string("diagnostic-secret")])
            Issue.record("An unrelated secret key unexpectedly passed ACP configuration validation.")
        } catch {
            #expect(!String(describing: error).contains("diagnostic-secret"))
        }
    }

    @Test("malformed argument and environment JSON is rejected")
    @MainActor
    func malformedJSONIsRejected() {
        #expect(throws: (any Error).self) {
            try backend(settings: ["command": .string("opencode"), "args": .string("{not-an-array}")])
        }
        #expect(throws: (any Error).self) {
            try backend(settings: ["command": .string("opencode"), "env": .string("[\"not\",\"an object\"]")])
        }
        #expect(throws: (any Error).self) {
            try backend(settings: ["command": .string("opencode"), "env": .string("{\"COUNT\":3}")])
        }
        #expect(throws: (any Error).self) {
            try backend(settings: ["command": .string("opencode"), "env": .string("{\"bad-name\":\"value\"}")])
        }
        #expect(throws: (any Error).self) {
            try backend(settings: ["command": .string("opencode"), "env": .string("{\"BAD=NAME\":\"value\"}")])
        }
    }

    @Test("configuration requires a command and rejects undeclared or secret values")
    @MainActor
    func requiredAndUnknownConfigurationIsRejected() {
        #expect(throws: (any Error).self) { try backend(settings: [:]) }
        #expect(throws: (any Error).self) {
            try backend(settings: ["command": .string("opencode"), "apiKey": .string("secret")])
        }
        #expect(throws: (any Error).self) {
            try backend(secrets: ["env.API_KEY": .string("secret")])
        }
    }

    @Test("configuration validation names an unusable setting without printing secret values")
    @MainActor
    func validateConfigurationFailsFastAndRedactsSecrets() throws {
        let secret = "validation-secret-\(UUID().uuidString)"
        let cwdBackend = try backend(
            settings: ["command": .string("/missing/acp-command"), "cwd": .string("/missing/acp-working-directory")],
            secrets: ["env-secret.API_TOKEN": .string(secret)]
        )

        do {
            try cwdBackend.validateConfiguration()
            Issue.record("Expected configuration validation to reject the missing cwd.")
        } catch let AscendantBackendError.invalidConfiguration(message) {
            #expect(message.contains("cwd"))
            #expect(!message.contains(secret))
        }

        let invalidCommand = try backend(settings: ["command": .string("/missing/acp-command")])
        do {
            try invalidCommand.validateConfiguration()
            Issue.record("Expected configuration validation to reject the missing executable.")
        } catch let AscendantBackendError.invalidConfiguration(message) {
            #expect(message.contains("command"))
        }
    }

    @Test("stderr secret redaction spans separate pipe reads")
    func stderrRedactionHandlesReadBoundaries() {
        let redactor = ACPStderrRedactor(secrets: ["private-token"])
        let first = redactor.consume(Data("agent says private-".utf8))
        let second = redactor.consume(Data("token and private-token again\n".utf8), finishing: true)
        let result = String(decoding: first + second, as: UTF8.self)
        #expect(result == "agent says [REDACTED] and [REDACTED] again\n")
        #expect(!result.contains("private-token"))

        let straddlingRedactor = ACPStderrRedactor(secrets: ["SECRET"])
        let prefix = straddlingRedactor.consume(Data("SECRET".utf8))
        let remainder = straddlingRedactor.consume(Data(), finishing: true)
        let straddlingResult = String(decoding: prefix + remainder, as: UTF8.self)
        #expect(straddlingResult == "[REDACTED]")
        #expect(!straddlingResult.contains("S"))
    }

    @Test("concurrent first connections spawn only one ACP process")
    @MainActor
    func concurrentConnectionEstablishmentIsSingleFlight() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let processIDs = stateHome.url.appendingPathComponent("process-ids.txt")
        let startCount = stateHome.url.appendingPathComponent("start-count.txt")
        let backend = try backend(
            settings: fixtureSettings(
                stateHome: stateHome.url,
                processPIDFile: processIDs,
                startCountFile: startCount
            ),
            timelines: [.init(id: UUID(), title: "Concurrent startup")]
        )

        async let first = backend.operatedTimelines()
        async let second = backend.operatedTimelines()
        _ = try await (first, second)
        await backend.shutdown()

        let starts = try String(contentsOf: startCount, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        #expect(starts.count == 1, "Concurrent startup launched \(starts.count) ACP processes.")
        let launchedPIDs = try String(contentsOf: processIDs, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0) }
        for pid in launchedPIDs { _ = kill(-pid, SIGKILL) }
    }

    @Test("shutdown waits for in-flight connection setup and leaves no process")
    @MainActor
    func shutdownDuringConnectionSetupCleansProcess() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let processIDs = stateHome.url.appendingPathComponent("process-ids.txt")
        let backend = try backend(settings: fixtureSettings(
            stateHome: stateHome.url,
            processPIDFile: processIDs,
            initializeDelayMilliseconds: 1_000
        ))
        let connection = Task { try await backend.operatedTimelines() }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: processIDs.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: processIDs.path))

        await backend.shutdown()
        do {
            _ = try await connection.value
            Issue.record("Connection setup unexpectedly completed after shutdown.")
        } catch { /* Shutdown rejects or interrupts the in-flight connection. */ }

        let launchedPIDs = try String(contentsOf: processIDs, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0) }
        for pid in launchedPIDs {
            #expect(kill(pid, 0) != 0, "ACP process \(pid) survived shutdown during connection setup")
        }
    }

    @Test("same-Timeline concurrent Turns do not replace active cancellation state")
    @MainActor
    func concurrentTurnsOnOneTimelineAreRejectedWithoutReplacingActiveTurn() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let promptStarted = stateHome.url.appendingPathComponent("prompt-started")
        let backend = try backend(
            settings: fixtureSettings(
                stateHome: stateHome.url,
                promptDelayMilliseconds: 1_000,
                promptStartedFile: promptStarted
            ),
            timelines: [.init(id: timelineID, title: "Single active Turn")]
        )
        let first = Task {
            try await backend.runTurn(
                .init(timelineID: timelineID, message: "first"),
                updates: RecordingUpdateSink()
            )
        }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: promptStarted.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: promptStarted.path))

        do {
            _ = try await backend.runTurn(
                .init(timelineID: timelineID, message: "second"),
                updates: RecordingUpdateSink()
            )
            Issue.record("A second same-Timeline Turn unexpectedly replaced the active Turn.")
        } catch let AscendantBackendError.terminal(failure) {
            #expect(failure.code == "acpTurnAlreadyActive")
        }
        #expect(try await first.value == "fixture reply: first")
        await backend.shutdown()
    }

    @Test("scoped cancellation reaches one ACP session and preserves another Timeline Turn")
    @MainActor
    func scopedCancellationStopsOnlyTheAddressedTimeline() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let firstTimelineID = UUID()
        let secondTimelineID = UUID()
        let cancelFile = stateHome.url.appendingPathComponent("cancelled-sessions.txt")
        let promptStarted = stateHome.url.appendingPathComponent("prompt-started")
        let backend = try backend(
            settings: fixtureSettings(
                stateHome: stateHome.url,
                promptStartedFile: promptStarted,
                cancellationFile: cancelFile
            ),
            timelines: [
                .init(id: firstTimelineID, title: "Cancel target"),
                .init(id: secondTimelineID, title: "Concurrent survivor"),
            ]
        )
        let cancelledUpdates = RecordingUpdateSink()
        let first = Task {
            try await backend.runTurn(
                .init(timelineID: firstTimelineID, message: "[fixture:wait]", clientTurnID: "turn-a"),
                updates: cancelledUpdates
            )
        }
        let second = Task {
            try await backend.runTurn(
                .init(timelineID: secondTimelineID, message: "survive", clientTurnID: "turn-b"),
                updates: RecordingUpdateSink()
            )
        }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: promptStarted.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: promptStarted.path))

        await backend.cancelTurn(timelineID: firstTimelineID, clientTurnID: " turn-a ")

        do {
            _ = try await first.value
            Issue.record("The addressed ACP Turn unexpectedly completed successfully.")
        } catch let error as AscendantBackendError {
            guard case .cancelled = error else {
                Issue.record("Expected ACP cancellation, received \(error).")
                await backend.shutdown()
                return
            }
        }
        do {
            #expect(try await second.value == "fixture reply: survive")
        } catch {
            Issue.record("The unrelated Timeline Turn failed after scoped cancellation: \(error).")
        }
        // The Runtime records `session/cancel` as it processes it, after the
        // Turn ended, so wait for the record instead of racing it.
        for _ in 0..<200 where wireEvents(cancelFile).isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let cancellationIDs = wireEvents(cancelFile)
        let sessionsData = try Data(contentsOf: stateHome.url.appendingPathComponent("\(backend.identity.id.uuidString).json"))
        let sessions = try #require(JSONSerialization.jsonObject(with: sessionsData) as? [String: [String: Any]])
        let targetSessionID = try #require(sessions[firstTimelineID.uuidString]?["sessionID"] as? String)
        #expect(cancellationIDs == [targetSessionID])
        #expect(await cancelledUpdates.updates.allSatisfy { $0.text != "late update" })
        await backend.shutdown()
    }

    @Test("shutdown terminates the agent process group and reaps its descendants")
    @MainActor
    func shutdownCleansProcessTree() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let pidFile = stateHome.url.appendingPathComponent("descendant.pid")
        let backend = try backend(settings: fixtureSettings(stateHome: stateHome.url, descendantPIDFile: pidFile))
        _ = try await backend.operatedTimelines()
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let childPID = try #require(Int32(pidText))

        await backend.shutdown()

        try await requireDead(pid: childPID, message: "ACP child process \(childPID) survived backend shutdown")
    }

    @Test("shutdown cleans the agent process group after its leader exits")
    @MainActor
    func shutdownCleansProcessTreeAfterLeaderExit() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let pidFile = stateHome.url.appendingPathComponent("descendant.pid")
        let leaderPIDFile = stateHome.url.appendingPathComponent("leader.pid")
        let leaderExitFile = stateHome.url.appendingPathComponent("leader-exited")
        let timelineID = UUID()
        let backend = try backend(
            settings: fixtureSettings(
                stateHome: stateHome.url,
                descendantPIDFile: pidFile,
                processExitFile: leaderExitFile,
                exitAfterPromptMilliseconds: 25,
                processPIDFile: leaderPIDFile
            ),
            timelines: [.init(id: timelineID, title: "Leader exits before retirement")]
        )
        _ = try await backend.operatedTimelines()
        let childPID = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        #expect(try await backend.runTurn(
            .init(timelineID: timelineID, message: "exit leader"),
            updates: RecordingUpdateSink()
        ) == "fixture reply: exit leader")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: leaderExitFile.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: leaderExitFile.path), "Fixture leader must exit before backend retirement")
        let leaderPIDText = try String(contentsOf: leaderPIDFile, encoding: .utf8)
        let leaderPID = try #require(Int32(leaderPIDText.split(whereSeparator: \.isNewline).first ?? ""))
        let processGroupID = try #require(backend.testProcessGroupID)
        #expect(processGroupID == leaderPID)
        for _ in 0..<500 where backend.testLeaderIsRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!backend.testLeaderIsRunning, "Foundation.Process must observe and reap the exited fixture leader before shutdown")
        #expect(kill(childPID, 0) == 0, "Fixture descendant must still be alive before backend retirement")
        #expect(getpgid(childPID) == processGroupID, "Fixture descendant must remain in the recorded process group")

        await backend.shutdown()

        try await requireDead(pid: childPID, message: "ACP descendant \(childPID) survived retirement after its leader exited")
        #expect(kill(-processGroupID, 0) != 0 && errno == ESRCH, "Recorded ACP process group survived backend retirement")
    }

    @Test("an ACP process crash during a prompt is insertionUnknown and makes the lifecycle unusable")
    @MainActor
    func crashIsLifecycleUnusable() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let secret = "crash-secret-\(UUID().uuidString)"
        let backend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url, crashOnPrompt: true),
            secrets: ["env-secret.API_TOKEN": .string(secret)],
            timelines: [.init(id: timelineID, title: "Crash")]
        )

        do {
            _ = try await backend.runTurn(.init(timelineID: timelineID, message: "crash"), updates: RecordingUpdateSink())
            Issue.record("Expected a crashed ACP process to leave the prompt's insertion unknown.")
        } catch let AscendantBackendError.insertionUnknown(failure) {
            // The prompt response was lost with the process, so the prompt may
            // have been inserted. The same failure retires the backend.
            #expect(failure?.code == "acpTransportUnusable")
            #expect(failure?.message.contains(secret) == false)
        }
        await backend.shutdown()
    }

    @Test("crashed process is quarantined and reconstructed once on the next Turn")
    @MainActor
    func crashQuarantinesAndReconstructsBackend() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let ascendantID = UUID()
        let timelineID = UUID()
        let crashMarker = stateHome.url.appendingPathComponent("crashed-once")
        let settings = try fixtureSettings(stateHome: stateHome.url, crashOnceMarker: crashMarker)
        let configuration = AscendantBackendConfiguration(kind: ACPAscendantBackend.kind, settings: settings)
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "acp-crash-\(UUID().uuidString.lowercased())"),
            node: .init(id: UUID()),
            ascendants: [.init(id: ascendantID, name: "Crash fixture", defaultTimelineID: timelineID, backend: configuration)],
            timelines: [.init(id: timelineID, title: "Crash recovery", operatingAscendantID: ascendantID, project: .local(stateHome.url.path))]
        )
        let factoryCount = BackendFactoryCount()
        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.registerBackend(
            kind: ACPAscendantBackend.kind,
            settings: ACPAscendantBackend.settingsSchema
        ) { ascendant, backendConfiguration, services, timelines in
            await factoryCount.increment()
            return try ACPAscendantBackend(
                ascendant: ascendant,
                configuration: backendConfiguration,
                services: services,
                timelines: timelines
            )
        }
        let journalDirectory = stateHome.url.appendingPathComponent("timeline-journals")
        let runtime = try await NodeRuntime(
            plan: manifest.compileLaunchPlan(), adapters: adapters, timelineJournalDirectory: journalDirectory
        )
        try await runtime.start()

        do {
            _ = try await runtime.turn(.init(message: "crash", timelineID: timelineID, clientTurnID: "crash-once"))
            Issue.record("Expected the first ACP Turn to end insertionUnknown.")
        } catch let AscendantTurnError.insertionUnknown(failedTimelineID, failedClientTurnID) {
            #expect(failedTimelineID == timelineID)
            #expect(failedClientTurnID == "crash-once")
        } catch {
            await runtime.shutdown()
            throw error
        }
        #expect(await runtime.backendHealth(for: ascendantID) == .failed)
        #expect(runtime.runtimeInstanceObject(for: ascendantID)?.health == .failed)

        let recovered = try await runtime.turn(.init(message: "recover", timelineID: timelineID, clientTurnID: "after-crash"))
        #expect(recovered.text == "fixture reply: recover")
        #expect(await factoryCount.value == 2)
        #expect(await runtime.backendHealth(for: ascendantID) == .healthy)
        #expect(runtime.runtimeInstanceObject(for: ascendantID)?.health == .healthy)
        await runtime.shutdown()
        let store = TimelineJournalStore(directoryURL: journalDirectory.appendingPathComponent(manifest.node.id.uuidString.lowercased()))
        let journal = try await store.journal(for: timelineID)
        #expect(await journal.timelineProjection()?.latestSession?.cwd == stateHome.url.standardizedFileURL.path)
        let records = try await journal.replay()
        #expect(records.contains { record in
            if case let .acpUpdate(_, update) = record.payload {
                return update.clientTurnID == "after-crash"
            }
            return false
        })
    }

    @Test("runtime-created Timeline does not prevent NodeRuntime restart")
    @MainActor
    func runtimeTimelineDoesNotPreventRestart() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let ascendantID = UUID()
        let configuredTimelineID = UUID()
        let configuration = AscendantBackendConfiguration(
            kind: ACPAscendantBackend.kind,
            settings: try fixtureSettings(stateHome: stateHome.url, paginatedListMode: "later-page")
        )
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "acp-restart-\(UUID().uuidString.lowercased())"),
            node: .init(id: UUID()),
            ascendants: [.init(id: ascendantID, name: "Restart fixture", defaultTimelineID: configuredTimelineID, backend: configuration)],
            timelines: [.init(id: configuredTimelineID, title: "Configured identity", operatingAscendantID: ascendantID)]
        )
        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.registerBackend(
            kind: ACPAscendantBackend.kind,
            settings: ACPAscendantBackend.settingsSchema
        ) { ascendant, backendConfiguration, services, timelines in
            try ACPAscendantBackend(
                ascendant: ascendant,
                configuration: backendConfiguration,
                services: services,
                timelines: timelines
            )
        }

        let firstRuntime = try await NodeRuntime(plan: manifest.compileLaunchPlan(), adapters: adapters)
        try await firstRuntime.start()
        let runtimeInstance = try #require(firstRuntime.runtimeInstanceObject(for: ascendantID))
        #expect(runtimeInstance.runtimeID == ascendantID)
        #expect(runtimeInstance.nodeID == manifest.node.id)
        #expect(runtimeInstance.runtimeKind == "local-command")
        #expect(runtimeInstance.runtimeVersion == "1")
        #expect(runtimeInstance.health == .healthy)
        #expect(runtimeInstance.rawCapabilities["session"] != nil)
        let createdTimeline = try await firstRuntime.createTimeline(title: "Process-scoped", ascendantID: ascendantID)
        #expect(createdTimeline.timelineID != configuredTimelineID)
        await firstRuntime.shutdown()
        #expect(firstRuntime.runtimeInstanceObject(for: ascendantID) == nil)

        let restartedRuntime = try await NodeRuntime(plan: manifest.compileLaunchPlan(), adapters: adapters)
        try await restartedRuntime.start()
        let snapshot = await restartedRuntime.snapshot()
        #expect(snapshot.operatedTimelineIDs == [configuredTimelineID])
        #expect(await restartedRuntime.timeline(id: configuredTimelineID)?.title == "Configured identity")
        #expect(await restartedRuntime.timeline(id: createdTimeline.timelineID) == nil)
        let configuredTurn = try await restartedRuntime.turn(.init(
            message: "verify configured session survives restart",
            timelineID: configuredTimelineID,
            clientTurnID: "configured-session-restart"
        ))
        #expect(configuredTurn.text == "fixture reply: verify configured session survives restart")
        await restartedRuntime.shutdown()
    }

    @Test("session list stops when an agent repeats its cursor")
    @MainActor
    func sessionListStopsOnRepeatedCursor() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let requestFile = stateHome.url.appendingPathComponent("list-requests.txt")
        let backend = try backend(
            settings: fixtureSettings(
                stateHome: stateHome.url,
                paginatedListMode: "repeating-cursor",
                listRequestFile: requestFile
            ),
            timelines: [.init(id: timelineID, title: "Configured")]
        )
        _ = try await backend.createTimeline(id: timelineID, title: "Configured")

        #expect(try await backend.operatedTimelines().map(\.id) == [timelineID])
        let requests = try String(contentsOf: requestFile, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        #expect(requests == ["first", "fixture-repeat"])
        await backend.shutdown()
    }

    @Test("session list stops at the maximum page count")
    @MainActor
    func sessionListStopsAtMaximumPageCount() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let requestFile = stateHome.url.appendingPathComponent("list-requests.txt")
        let backend = try backend(
            settings: fixtureSettings(
                stateHome: stateHome.url,
                paginatedListMode: "unbounded",
                listRequestFile: requestFile
            )
        )

        #expect(try await backend.operatedTimelines().isEmpty)
        let requests = try String(contentsOf: requestFile, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        #expect(requests.count == 100)
        await backend.shutdown()
    }

    @Test("an agent that exits during session pagination fails cleanly and a fresh backend recovers")
    @MainActor
    func paginationAgentExitIsBoundedAndRecoverable() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let configuredTimelineID = UUID()

        // The faulted agent answers page one with a cursor and exits on page two.
        let faulted = try backend(
            settings: fixtureSettings(
                stateHome: stateHome.url,
                paginatedListMode: "later-page",
                listExitAfter: 2
            ),
            timelines: [.init(id: configuredTimelineID, title: "Configured")]
        )
        do {
            _ = try await faulted.operatedTimelines()
            Issue.record("Exiting during session pagination did not surface as a failure.")
        } catch let error as AscendantBackendError {
            guard case .lifecycleUnusable = error else {
                Issue.record("Expected lifecycleUnusable from a dead pagination agent, got \(error).")
                await faulted.shutdown()
                return
            }
        }
        await faulted.shutdown()

        // A backend without the fault serves the same configured Timeline.
        let healthy = try backend(
            settings: fixtureSettings(stateHome: stateHome.url, paginatedListMode: "later-page"),
            timelines: [.init(id: configuredTimelineID, title: "Configured")]
        )
        #expect(try await healthy.operatedTimelines().map(\.id) == [configuredTimelineID])
        let response = try await healthy.runTurn(
            .init(timelineID: configuredTimelineID, message: "after pagination exit"),
            updates: RecordingUpdateSink()
        )
        #expect(response == "fixture reply: after pagination exit")
        await healthy.shutdown()
    }

    @Test("Node startup fails cleanly when the agent exits during pagination and a restart recovers")
    @MainActor
    func nodeStartupSurvivesPaginationExit() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let ascendantID = UUID()
        let timelineID = UUID()

        func makeRuntime(listExitAfter: Int?) async throws -> NodeRuntime {
            let manifest = NodeManifest(
                broker: .init(host: "127.0.0.1", port: 1883, namespace: "acp-pagination-\(UUID().uuidString.lowercased())"),
                node: .init(id: UUID()),
                ascendants: [.init(
                    id: ascendantID,
                    name: "Pagination fixture",
                    defaultTimelineID: timelineID,
                    backend: .init(
                        kind: ACPAscendantBackend.kind,
                        settings: try fixtureSettings(
                            stateHome: stateHome.url,
                            paginatedListMode: "later-page",
                            listExitAfter: listExitAfter
                        )
                    )
                )],
                timelines: [.init(id: timelineID, title: "Configured", operatingAscendantID: ascendantID)]
            )
            var adapters = NodeRuntimeAdapters.default
            adapters.ascendants.registerBackend(
                kind: ACPAscendantBackend.kind,
                settings: ACPAscendantBackend.settingsSchema
            ) { ascendant, configuration, services, timelines in
                try ACPAscendantBackend(
                    ascendant: ascendant,
                    configuration: configuration,
                    services: services,
                    timelines: timelines
                )
            }
            let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan(), adapters: adapters)
            try await runtime.start()
            return runtime
        }

        do {
            _ = try await makeRuntime(listExitAfter: 2)
            Issue.record("Node startup succeeded while the agent exited during session pagination.")
        } catch {
            // Startup must fail rather than hang or crash the process.
        }

        let restarted = try await makeRuntime(listExitAfter: nil)
        let turn = try await restarted.turn(.init(
            message: "restarted after pagination exit",
            timelineID: timelineID,
            clientTurnID: "pagination-restart"
        ))
        #expect(turn.text == "fixture reply: restarted after pagination exit")
        await restarted.shutdown()
    }

    @Test("Timeline operations are idempotent and unknown removals are ignored")
    @MainActor
    func timelineOperationsAreIdempotent() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let configuredID = UUID()
        let timeline = NodeManifest.Timeline(id: configuredID, title: "Configured")
        let backend = try fixtureBackend(timelines: [timeline], stateHome: stateHome.url)

        _ = try await backend.createTimeline(id: configuredID, title: timeline.title)
        #expect(try await backend.operatedTimelines().map(\.id) == [configuredID])
        let created = try await backend.createTimeline(id: UUID(), title: "Runtime")
        let createdAgain = try await backend.createTimeline(id: created.id, title: "Ignored")
        #expect(createdAgain.id == created.id)
        #expect(try await backend.operatedTimelines().count == 2)
        let renamed = try await backend.renameTimeline(id: created.id, title: "Renamed")
        #expect(renamed.title == "Renamed")
        await backend.removeTimeline(id: created.id)
        await backend.removeTimeline(id: created.id)
        #expect(try await backend.operatedTimelines().map(\.id) == [configuredID])
        await backend.shutdown()
    }

    @Test("runTurn streams assistant and tool updates before a terminal completion")
    @MainActor
    func runTurnStreamsFixtureEvents() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let backend = try fixtureBackend(timelines: [.init(id: timelineID, title: "Configured")], stateHome: stateHome.url)
        let sink = RecordingUpdateSink()

        let result = try await backend.runTurn(
            .init(timelineID: timelineID, message: "hello"),
            updates: sink
        )

        #expect(result == "fixture reply: hello")
        let updates = await sink.updates
        #expect(updates.map(\.kind) == [
            .assistantText,
            .assistantText,
            .toolCall,
            .toolState,
            .completion,
        ])
        #expect(updates.map(\.text).compactMap { $0 }.joined() == "fixture reply: hello")
        #expect(updates[2].toolState?.toolStatus == .pending)
        #expect(updates[3].toolState?.toolStatus == .completed)
        #expect(updates.last?.terminal == true)

        let limitedSink = RecordingUpdateSink()
        do {
            _ = try await backend.runTurn(
                .init(timelineID: timelineID, message: "[fixture:max-tokens]"),
                updates: limitedSink
            )
            Issue.record("Expected the fixture's max_tokens stop reason to be terminal.")
        } catch let AscendantBackendError.terminal(failure) {
            #expect(failure.code == "acpTurnStopped")
        }
        #expect(await limitedSink.updates.last?.kind == AscendantTurnUpdateKind.error)
        await backend.shutdown()
    }

    @Test("a Turn ends when the agent reports an idle without a stop reason")
    @MainActor
    func idleWithoutStopReasonEndsTheTurn() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let backend = try fixtureBackend(timelines: [.init(id: timelineID, title: "Configured")], stateHome: stateHome.url)
        let sink = RecordingUpdateSink()

        // An omitted stop reason ends the Turn with an unspecified reason,
        // which is neither success nor failure (ADR 0019 §2).
        let result = try await backend.runTurn(
            .init(timelineID: timelineID, message: "[fixture:idle-without-stop-reason]"),
            updates: sink
        )

        #expect(result == "fixture reply: [fixture:idle-without-stop-reason]")
        #expect(await sink.updates.last?.kind == .completion)
        await backend.shutdown()
    }

    @Test("a whole agent message upsert replaces the accumulated assistant text")
    @MainActor
    func wholeAgentMessageUpsertBecomesTheAssistantText() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let backend = try fixtureBackend(timelines: [.init(id: timelineID, title: "Configured")], stateHome: stateHome.url)
        let sink = RecordingUpdateSink()

        let result = try await backend.runTurn(
            .init(timelineID: timelineID, message: "[fixture:agent-message]"),
            updates: sink
        )

        #expect(result == "upserted reply: [fixture:agent-message]")
        let texts = await sink.updates.map(\.text).compactMap { $0 }
        #expect(texts == ["upserted reply: [fixture:agent-message]"])
        await backend.shutdown()
    }

    @Test("prompt deadline exceeds the shorter protocol default")
    @MainActor
    func promptDeadlineIsSeparateFromProtocolDefault() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let backend = try backend(
            settings: fixtureSettings(
                stateHome: stateHome.url,
                promptProgressDurationMilliseconds: 900,
                promptProgressIntervalMilliseconds: 100
            ),
            timelines: [.init(id: timelineID, title: "Long Turn")],
            protocolTimeoutSeconds: 0.5,
            promptTimeoutSeconds: 5
        )
        let sink = RecordingUpdateSink()

        let response = try await backend.runTurn(
            .init(timelineID: timelineID, message: "do long work"),
            updates: sink
        )

        #expect(response.contains("fixture reply: do long work"))
        #expect(await sink.updates.filter { $0.kind == AscendantTurnUpdateKind.assistantText }.count >= 6)
        #expect(try await backend.operatedTimelines().map(\.id) == [timelineID])
        await backend.shutdown()
    }

    @Test("fixture permission requests are mediated and approved using the advertised allow-once option")
    @MainActor
    func fixturePermissionRequestCanBeApproved() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let store = TimelineJournalStore(directoryURL: stateHome.url.appendingPathComponent("journals"))
        let permission = RecordingPermissionService(decision: .approved)
        let backend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url, permissionPrompt: true),
            timelines: [.init(id: timelineID, title: "Configured")],
            permission: permission,
            optionalCapabilities: [TimelineJournalRecorder(journals: store)]
        )

        let response = try await backend.runTurn(
            .init(timelineID: timelineID, message: "approve permission", clientTurnID: "approve-once"),
            updates: RecordingUpdateSink()
        )

        #expect(response == "fixture reply: approve permission")
        let requests = await permission.requests
        #expect(requests.count == 1)
        #expect(requests.first?.timelineID == timelineID)
        #expect(requests.first?.clientTurnID == "approve-once")
        #expect(requests.first?.toolCallID == "fixture-permission-tool")
        #expect(requests.first?.title == "Inspect fixture input")
        let journal = try await store.journal(for: timelineID)
        let records = try await journal.replay()
        let decisionIndex = records.firstIndex { record in
            if case let .permissionDecision(_, clientTurnID, decision, approved) = record.payload {
                return clientTurnID == "approve-once" && decision == "approved" && approved
            }
            return false
        }
        #expect(decisionIndex != nil)
        await backend.shutdown()
    }

    @Test("ACP cancels approval when its Timeline journal becomes unwritable")
    @MainActor
    func permissionFailsClosedWhenJournalQuarantines() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let store = TimelineJournalStore(directoryURL: stateHome.url.appendingPathComponent("journals"))
        let journal = try await store.journal(for: timelineID)
        let permission = JournalFailingPermissionService(journal: journal)
        let resultFile = stateHome.url.appendingPathComponent("permission-result.json")
        let instance = try backend(
            settings: fixtureSettings(
                stateHome: stateHome.url, permissionPrompt: true, permissionOutcome: "cancelled",
                permissionResultFile: resultFile
            ),
            timelines: [.init(id: timelineID, title: "Permission")], permission: permission,
            optionalCapabilities: [TimelineJournalRecorder(journals: store)]
        )
        do {
            _ = try await instance.runTurn(
                .init(timelineID: timelineID, message: "fail closed", clientTurnID: "fail-closed"), updates: RecordingUpdateSink()
            )
        } catch { /* The quarantined journal also rejects subsequent ACP updates. */ }
        #expect(await permission.injectedFailure)
        let outcome = try String(contentsOf: resultFile, encoding: .utf8)
        #expect(outcome == #"{"outcome":"cancelled"}"#)
        await instance.shutdown()
    }

    @Test("fixture permission denial maps to the advertised reject-once option")
    @MainActor
    func fixturePermissionRequestCanBeDenied() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let permission = RecordingPermissionService(decision: .denied)
        let backend = try backend(
            settings: fixtureSettings(
                stateHome: stateHome.url,
                permissionPrompt: true,
                permissionOutcome: "selected:reject-once"
            ),
            timelines: [.init(id: timelineID, title: "Configured")],
            permission: permission
        )

        let response = try await backend.runTurn(
            .init(timelineID: timelineID, message: "deny permission", clientTurnID: "deny-once"),
            updates: RecordingUpdateSink()
        )

        #expect(response == "fixture reply: deny permission")
        #expect(await permission.requests.count == 1)
        await backend.shutdown()
    }

    @Test("Claude Agent approval selects its narrow allow option, not allow_always")
    @MainActor
    func claudePermissionApprovalSelectsAllow() async throws {
        try await assertClaudePermission(
            decision: .approved,
            permissionOutcome: "selected:allow"
        )
    }

    @Test("Claude Agent denial selects its reject option")
    @MainActor
    func claudePermissionDenialSelectsReject() async throws {
        try await assertClaudePermission(
            decision: .denied,
            permissionOutcome: "selected:reject"
        )
    }

    @MainActor
    private func assertClaudePermission(
        decision: AscendantPermissionDecision,
        permissionOutcome: String
    ) async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let permission = RecordingPermissionService(decision: decision)
        let backend = try backend(
            settings: fixtureSettings(
                stateHome: stateHome.url,
                permissionPrompt: true,
                permissionOutcome: permissionOutcome,
                claudePermissionOptions: true
            ),
            timelines: [.init(id: timelineID, title: "Configured")],
            permission: permission,
            promptTimeoutSeconds: 5
        )

        let response = try await backend.runTurn(
            .init(timelineID: timelineID, message: "handle Claude permission", clientTurnID: "claude-permission"),
            updates: RecordingUpdateSink()
        )

        #expect(response == "fixture reply: handle Claude permission")
        let requests = await permission.requests
        #expect(requests.count == 1)
        #expect(requests.first?.timelineID == timelineID)
        #expect(requests.first?.clientTurnID == "claude-permission")
        await backend.shutdown()
    }

    @Test("unavailable permission mediation cancels the ACP request instead of approving it")
    @MainActor
    func fixturePermissionRequestUnavailableFailsClosed() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let store = TimelineJournalStore(directoryURL: stateHome.url.appendingPathComponent("journals"))
        let permission = RecordingPermissionService(decision: .unavailable(reason: "hostUnavailable"))
        let backend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url, permissionPrompt: true, permissionOutcome: "cancelled"),
            timelines: [.init(id: timelineID, title: "Configured")],
            permission: permission,
            optionalCapabilities: [TimelineJournalRecorder(journals: store)]
        )

        // The fixture asserts the `cancelled` outcome on the wire. The completed
        // reply proves that the unanswered request did not end the Turn.
        let response = try await backend.runTurn(
            .init(timelineID: timelineID, message: "handle unavailable permission", clientTurnID: "unavailable-once"),
            updates: RecordingUpdateSink()
        )

        #expect(response == "fixture reply: handle unavailable permission")
        #expect(await permission.requests.count == 1)
        let records = try await store.journal(for: timelineID).replay()
        let decisions = records.compactMap { record -> (String, Bool)? in
            if case let .permissionDecision(_, clientTurnID, decision, approved) = record.payload,
               clientTurnID == "unavailable-once" {
                return (decision, approved)
            }
            return nil
        }
        #expect(decisions.count == 1)
        #expect(decisions.first?.0 == "unavailable")
        #expect(decisions.first?.1 == false)
        await backend.shutdown()
    }

    @Test("a permission request nobody answers reaches the agent as cancelled, keeps the Turn, and is journaled unavailable")
    @MainActor
    func unansweredPermissionKeepsTheTurn() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let store = TimelineJournalStore(directoryURL: stateHome.url.appendingPathComponent("journals"))
        // No client ever responds to this coordinator. Only its bound can end the request.
        let permission = AscendantPermissionCoordinator(updates: AscendantTurnUpdateStore(), unansweredBound: .milliseconds(100))
        let backend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url, permissionPrompt: true, permissionOutcome: "cancelled"),
            timelines: [.init(id: timelineID, title: "Configured")],
            permission: permission,
            optionalCapabilities: [TimelineJournalRecorder(journals: store)]
        )

        let response = try await backend.runTurn(
            .init(timelineID: timelineID, message: "nobody answers", clientTurnID: "unanswered-once"),
            updates: RecordingUpdateSink()
        )

        #expect(response == "fixture reply: nobody answers")
        let records = try await store.journal(for: timelineID).replay()
        let decisions = records.compactMap { record -> String? in
            if case let .permissionDecision(_, clientTurnID, decision, approved) = record.payload,
               clientTurnID == "unanswered-once", !approved {
                return decision
            }
            return nil
        }
        #expect(decisions == ["unavailable"])
        await backend.shutdown()
    }

    @Test("missing permission mediation service cancels the ACP request")
    @MainActor
    func missingPermissionServiceFailsClosed() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let backend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url, permissionPrompt: true, permissionOutcome: "cancelled"),
            timelines: [.init(id: timelineID, title: "Configured")]
        )

        let response = try await backend.runTurn(
            .init(timelineID: timelineID, message: "handle missing permission service"),
            updates: RecordingUpdateSink()
        )

        #expect(response == "fixture reply: handle missing permission service")
        await backend.shutdown()
    }

    @Test("unsupported permission options fail closed without asking the host to approve")
    @MainActor
    func unsupportedPermissionOptionsFailClosed() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let permission = RecordingPermissionService(decision: .approved)
        let backend = try backend(
            settings: fixtureSettings(
                stateHome: stateHome.url,
                permissionPrompt: true,
                permissionOutcome: "cancelled",
                unsupportedPermissionOptions: true
            ),
            timelines: [.init(id: timelineID, title: "Configured")],
            permission: permission
        )

        let response = try await backend.runTurn(
            .init(timelineID: timelineID, message: "reject unsupported options"),
            updates: RecordingUpdateSink()
        )

        #expect(response == "fixture reply: reject unsupported options")
        #expect(await permission.requests.isEmpty)
        await backend.shutdown()
    }

    @Test("a backend-wide cancel resolves an in-flight permission request and surfaces cancellation")
    @MainActor
    func cancelledTurnCancelsPermissionRequest() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let permission = DelayedPermissionService()
        let backend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url, permissionPrompt: true, permissionOutcome: "cancelled"),
            timelines: [.init(id: timelineID, title: "Configured")],
            permission: permission
        )
        let turn = Task {
            try await backend.runTurn(
                .init(timelineID: timelineID, message: "cancel permission request"),
                updates: RecordingUpdateSink()
            )
        }

        guard await permission.waitForRequest() != nil else {
            Issue.record("The fixture did not issue its permission request before the deadline.")
            await backend.shutdown()
            return
        }
        // Cancelling the backend resumes the in-flight permission request so the
        // agent is not stranded, and the Turn surfaces as cancelled.
        await backend.cancel()
        await permission.resolve(.approved)
        do {
            _ = try await turn.value
            Issue.record("A backend-wide cancel left the in-flight Turn uncancelled.")
        } catch let error as AscendantBackendError {
            #expect(error == .cancelled)
        }
        await backend.shutdown()
    }

    @Test("scoped cancellation settles while host permission remains unresolved")
    @MainActor
    func scopedCancellationUnblocksPendingPermission() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let cancelFile = stateHome.url.appendingPathComponent("cancelled-sessions.txt")
        let permission = DelayedPermissionService()
        let backend = try backend(
            settings: fixtureSettings(
                stateHome: stateHome.url,
                permissionPrompt: true,
                permissionOutcome: "cancelled",
                cancellationFile: cancelFile
            ),
            timelines: [.init(id: timelineID, title: "Pending permission")],
            permission: permission
        )
        let turn = Task {
            try await backend.runTurn(
                .init(timelineID: timelineID, message: "wait for permission", clientTurnID: "permission-turn"),
                updates: RecordingUpdateSink()
            )
        }

        guard await permission.waitForRequest() != nil else {
            Issue.record("The fixture did not issue its permission request before the deadline.")
            await backend.shutdown()
            return
        }
        await backend.cancelTurn(timelineID: timelineID, clientTurnID: "permission-turn")
        for _ in 0..<100 where await permission.cancellationCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await permission.cancellationCount == 1)

        do {
            _ = try await turn.value
            Issue.record("The Turn with an unresolved permission request unexpectedly succeeded.")
        } catch let error as AscendantBackendError {
            guard case .cancelled = error else {
                Issue.record("Expected cancellation, received \(error).")
                await backend.shutdown()
                return
            }
        }
        // The Runtime records `session/cancel` as it processes it, after the
        // Turn ended, so wait for the record instead of racing it.
        for _ in 0..<200 where wireEvents(cancelFile).isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(wireEvents(cancelFile).count == 1)
        await backend.shutdown()
    }

    @Test("agent terminal failures are terminal and leave the backend usable")
    @MainActor
    func agentFailureIsTerminal() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let backend = try fixtureBackend(timelines: [.init(id: timelineID, title: "Configured")], stateHome: stateHome.url)
        do {
            _ = try await backend.runTurn(
                .init(timelineID: timelineID, message: "[fixture:terminal-error]"),
                updates: RecordingUpdateSink()
            )
            Issue.record("Expected the fixture's terminal error.")
        } catch let AscendantBackendError.terminal(failure) {
            #expect(failure.message.contains("fixture terminal error"))
        }
        #expect(try await backend.operatedTimelines().map(\.id) == [timelineID])
        await backend.shutdown()
    }

    @Test("runtime Timeline session mappings are discarded after backend restart")
    @MainActor
    func runtimeTimelineMappingIsDiscardedAfterRestart() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let ascendantID = UUID()
        let timelineID = UUID()
        let timeline = NodeManifest.Timeline(id: timelineID, title: "Runtime")
        let settings = try fixtureSettings(stateHome: stateHome.url)
        let first = try backend(settings: settings, timelines: [], ascendantID: ascendantID)
        _ = try await first.createTimeline(id: timelineID, title: timeline.title)
        _ = try await first.runTurn(
            .init(timelineID: timelineID, message: "create the durable session"),
            updates: RecordingUpdateSink()
        )
        await first.shutdown()

        let restarted = try backend(settings: settings, timelines: [], ascendantID: ascendantID)
        let storedSessionMap = try Data(contentsOf: stateHome.url.appendingPathComponent("\(ascendantID.uuidString).json"))
        let storedSessions = try #require(JSONSerialization.jsonObject(with: storedSessionMap) as? [String: Any])
        #expect(storedSessions.isEmpty)
        let firstList = try await restarted.operatedTimelines()
        let secondList = try await restarted.operatedTimelines()
        #expect(firstList.isEmpty)
        #expect(secondList.isEmpty)
        await #expect(throws: AscendantBackendError.timelineNotFound(timelineID)) {
            try await restarted.runTurn(
                .init(timelineID: timelineID, message: "runtime Timelines do not survive restart"),
                updates: RecordingUpdateSink()
            )
        }
        await restarted.removeTimeline(id: UUID())
        #expect(try await restarted.operatedTimelines().isEmpty)
        await restarted.shutdown()
    }

    @Test("session list omission falls back to local Gnostic Timeline projections")
    @MainActor
    func sessionListCapabilityIsOptional() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let timeline = NodeManifest.Timeline(id: timelineID, title: "Configured")
        let backend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url, supportsList: false),
            timelines: [timeline]
        )

        #expect(try await backend.operatedTimelines().map(\.id) == [timelineID])
        await backend.shutdown()
    }

    @Test("failed best-effort session close does not poison the backend")
    @MainActor
    func failedSessionCloseDoesNotPoisonBackend() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let initialID = UUID()
        let backend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url, failClose: true),
            timelines: [.init(id: initialID, title: "Initial")]
        )

        _ = try await backend.createTimeline(id: initialID, title: "Initial")
        await backend.removeTimeline(id: initialID)
        let replacementID = UUID()
        _ = try await backend.createTimeline(id: replacementID, title: "Replacement")
        let response = try await backend.runTurn(
            .init(timelineID: replacementID, message: "backend remains usable"),
            updates: RecordingUpdateSink()
        )
        #expect(response == "fixture reply: backend remains usable")
        await backend.shutdown()
    }

    // MARK: - AscendantBackend conformance (GNO-PLAT-060, #452)

    @Test("conformance: identity and configuration")
    @MainActor
    func conformanceIdentityAndConfiguration() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let fixture = conformanceFixture(stateHome: stateHome.url, signal: AscendantConformanceTurnSignal())
        try await fixture.suite().checkIdentityAndConfiguration()
    }

    @Test("conformance: capability declaration agrees with conformance and fixture surfaces")
    @MainActor
    func conformanceCapabilityDeclarationAgrees() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let fixture = conformanceFixture(stateHome: stateHome.url, signal: AscendantConformanceTurnSignal())
        try await fixture.suite().checkCapabilityDeclarationAgrees()
    }

    @Test("conformance: Workspace attachment is projected")
    @MainActor
    func conformanceWorkspaceAttachmentProjects() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let fixture = conformanceFixture(stateHome: stateHome.url, signal: AscendantConformanceTurnSignal())
        try await fixture.suite().checkWorkspaceAttachmentProjects()
    }

    @Test("conformance: Timeline lifecycle")
    @MainActor
    func conformanceTimelineLifecycle() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let fixture = conformanceFixture(stateHome: stateHome.url, signal: AscendantConformanceTurnSignal())
        try await fixture.suite().checkTimelineLifecycle()
    }

    @Test("conformance: a successful Turn streams and returns text")
    @MainActor
    func conformanceSuccessfulTurn() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let fixture = conformanceFixture(stateHome: stateHome.url, signal: AscendantConformanceTurnSignal())
        try await fixture.suite().checkSuccessfulTurnStreamsText()
    }

    @Test("conformance: a terminal failure leaves the backend usable")
    @MainActor
    func conformanceTerminalFailure() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let fixture = conformanceFixture(stateHome: stateHome.url, signal: AscendantConformanceTurnSignal())
        try await fixture.suite().checkTerminalFailureKeepsBackendUsable()
    }

    @Test("conformance: backend cancellation interrupts a stalled Turn")
    @MainActor
    func conformanceBackendCancellation() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let fixture = conformanceFixture(stateHome: stateHome.url, signal: AscendantConformanceTurnSignal())
        try await fixture.suite().checkBackendCancellationInterruptsStall()
    }

    @Test("conformance: scoped cancellation interrupts a stalled Turn")
    @MainActor
    func conformanceScopedCancellation() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let fixture = conformanceFixture(stateHome: stateHome.url, signal: AscendantConformanceTurnSignal())
        try await fixture.suite().checkScopedCancellationInterruptsStall()
    }

    @Test("conformance: health, quarantine, reconstruction, and replay")
    @MainActor
    func conformanceHostHealthQuarantineAndReplay() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let fixture = conformanceHostFixture(stateHome: stateHome.url)
        try await fixture.suite().checkHealthQuarantineAndReplay()
    }

    /// The ACP backend implements the Workspace capability through the Gnostic gateway.
    @MainActor
    private func conformanceFixture(stateHome: URL, signal: AscendantConformanceTurnSignal) -> AscendantConformanceFixture {
        let workspace = AscendantConformanceWorkspaceService()
        return AscendantConformanceFixture(
            kind: ACPAscendantBackend.kind,
            surfaces: [.scopedCancellation, .terminalUpdate, .workspaceAttachment],
            workspaceService: workspace,
            expectedReply: { "fixture reply: \($0)" },
            awaitTurnStarted: { _ = await signal.waitUntilStarted() },
            makeBackend: { ascendant, timelines in
                let startedFile = stateHome.appendingPathComponent("prompt-started-\(UUID().uuidString).txt")
                watchACPStallStart(url: startedFile, signal: signal)
                let settings = try self.fixtureSettings(stateHome: stateHome, promptStartedFile: startedFile)
                let configured = NodeManifest.Ascendant(
                    id: ascendant.id,
                    name: ascendant.name,
                    defaultTimelineID: ascendant.defaultTimelineID,
                    backend: .init(kind: ACPAscendantBackend.kind, settings: settings)
                )
                return try ACPAscendantBackend(
                    ascendant: configured,
                    configuration: configured.backend,
                    services: AscendantBackendServices(workspace: workspace, permission: AscendantConformancePermissionService()),
                    timelines: timelines
                )
            }
        )
    }

    /// A host-level ACP fixture. `shutdown()` makes the live backend report
    /// lifecycle-unusable, so that breaks it until reconstruction.
    @MainActor
    private func conformanceHostFixture(stateHome: URL) -> AscendantHostConformanceFixture {
        let box = AscendantConformanceBackendBox()
        return AscendantHostConformanceFixture(
            kind: ACPAscendantBackend.kind,
            makeAdapters: {
                var adapters = NodeRuntimeAdapters.default
                adapters.ascendants.registerBackend(
                    kind: ACPAscendantBackend.kind,
                    settings: ACPAscendantBackend.settingsSchema
                ) { ascendant, _, services, timelines in
                    let settings = try self.fixtureSettings(stateHome: stateHome)
                    let configured = NodeManifest.Ascendant(
                        id: ascendant.id,
                        name: ascendant.name,
                        defaultTimelineID: ascendant.defaultTimelineID,
                        backend: .init(kind: ACPAscendantBackend.kind, settings: settings)
                    )
                    let backend = try ACPAscendantBackend(
                        ascendant: configured,
                        configuration: configured.backend,
                        services: services,
                        timelines: timelines
                    )
                    box.hold(backend)
                    return backend
                }
                return adapters
            },
            breakLiveBackend: {
                await box.backend?.shutdown()
            }
        )
    }

    /// Marks the shared signal once the ACP fixture writes its prompt-started file.
    private func watchACPStallStart(url: URL, signal: AscendantConformanceTurnSignal) {
        Task {
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: url.path) {
                    await signal.markStarted()
                    return
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    @MainActor
    private func fixtureBackend(
        timelines: [NodeManifest.Timeline],
        ascendantID: UUID = UUID(),
        stateHome: URL
    ) throws -> ACPAscendantBackend {
        try backend(settings: fixtureSettings(stateHome: stateHome), timelines: timelines, ascendantID: ascendantID)
    }

    private func fixtureSettings(
        stateHome: URL,
        supportsList: Bool = true,
        mcpGateway: Bool = false,
        paginatedListMode: String? = nil,
        listExitAfter: Int? = nil,
        listRequestFile: URL? = nil,
        failClose: Bool = false,
        permissionPrompt: Bool = false,
        permissionOutcome: String = "selected:allow-once",
        permissionResultFile: URL? = nil,
        unsupportedPermissionOptions: Bool = false,
        claudePermissionOptions: Bool = false,
        requiredAbsentEnvironmentKey: String? = nil,
        crashOnPrompt: Bool = false,
        descendantPIDFile: URL? = nil,
        processExitFile: URL? = nil,
        exitAfterPromptMilliseconds: Int? = nil,
        crashOnceMarker: URL? = nil,
        processPIDFile: URL? = nil,
        startCountFile: URL? = nil,
        initializeDelayMilliseconds: Int? = nil,
        promptDelayMilliseconds: Int? = nil,
        promptProgressDurationMilliseconds: Int? = nil,
        promptProgressIntervalMilliseconds: Int? = nil,
        promptStartedFile: URL? = nil,
        cancellationFile: URL? = nil,
        wireLogFile: URL? = nil,
        promptRequestFile: URL? = nil,
        initializeProtocolVersion: Int? = nil,
        initializeExtraCapabilities: String? = nil
    ) throws -> [String: ManifestJSONValue] {
        let fixturePath = ProcessInfo.processInfo.environment["GNOSTIC_ACP_AGENT_FIXTURE"]
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/ACPAgent/agent.mjs")
                .path
        let statePath = stateHome.appendingPathComponent("agent-sessions.json").path
        var fixtureEnvironment = ["GNOSTIC_ACP_FIXTURE_STATE": statePath]
        if mcpGateway { fixtureEnvironment["GNOSTIC_ACP_FIXTURE_MCP"] = "1" }
        if !supportsList { fixtureEnvironment["GNOSTIC_ACP_FIXTURE_NO_LIST"] = "1" }
        if let paginatedListMode { fixtureEnvironment["GNOSTIC_ACP_FIXTURE_PAGINATED_LIST"] = paginatedListMode }
        if let listExitAfter { fixtureEnvironment["GNOSTIC_ACP_FIXTURE_LIST_EXIT_AFTER"] = String(listExitAfter) }
        if let listRequestFile { fixtureEnvironment["GNOSTIC_ACP_FIXTURE_LIST_REQUEST_FILE"] = listRequestFile.path }
        if failClose { fixtureEnvironment["GNOSTIC_ACP_FIXTURE_CLOSE_ERROR"] = "1" }
        if permissionPrompt {
            fixtureEnvironment["GNOSTIC_ACP_FIXTURE_PERMISSION"] = "1"
            fixtureEnvironment["GNOSTIC_ACP_FIXTURE_PERMISSION_OUTCOME"] = permissionOutcome
        }
        if let permissionResultFile { fixtureEnvironment["GNOSTIC_ACP_FIXTURE_PERMISSION_RESULT_FILE"] = permissionResultFile.path }
        if unsupportedPermissionOptions { fixtureEnvironment["GNOSTIC_ACP_FIXTURE_PERMISSION_UNSUPPORTED"] = "1" }
        if claudePermissionOptions { fixtureEnvironment["GNOSTIC_ACP_FIXTURE_PERMISSION_CLAUDE"] = "1" }
        if let requiredAbsentEnvironmentKey {
            fixtureEnvironment["GNOSTIC_ACP_FIXTURE_PARENT_ONLY_KEY"] = requiredAbsentEnvironmentKey
        }
        if crashOnPrompt { fixtureEnvironment["GNOSTIC_ACP_FIXTURE_CRASH_ON_PROMPT"] = "1" }
        if let descendantPIDFile { fixtureEnvironment["GNOSTIC_ACP_FIXTURE_CHILD_PID_FILE"] = descendantPIDFile.path }
        if let processExitFile { fixtureEnvironment["GNOSTIC_ACP_FIXTURE_PROCESS_EXIT_FILE"] = processExitFile.path }
        if let exitAfterPromptMilliseconds {
            fixtureEnvironment["GNOSTIC_ACP_FIXTURE_EXIT_AFTER_PROMPT_MS"] = String(exitAfterPromptMilliseconds)
        }
        if let crashOnceMarker { fixtureEnvironment["GNOSTIC_ACP_FIXTURE_CRASH_ONCE_FILE"] = crashOnceMarker.path }
        if let processPIDFile { fixtureEnvironment["GNOSTIC_ACP_FIXTURE_PROCESS_PID_FILE"] = processPIDFile.path }
        if let startCountFile { fixtureEnvironment["GNOSTIC_ACP_FIXTURE_START_COUNT_FILE"] = startCountFile.path }
        if let initializeDelayMilliseconds {
            fixtureEnvironment["GNOSTIC_ACP_FIXTURE_INITIALIZE_DELAY_MS"] = String(initializeDelayMilliseconds)
        }
        if let initializeProtocolVersion {
            fixtureEnvironment["GNOSTIC_ACP_FIXTURE_PROTOCOL_VERSION"] = String(initializeProtocolVersion)
        }
        if let initializeExtraCapabilities {
            fixtureEnvironment["GNOSTIC_ACP_FIXTURE_EXTRA_CAPABILITIES"] = initializeExtraCapabilities
        }
        if let promptDelayMilliseconds {
            fixtureEnvironment["GNOSTIC_ACP_FIXTURE_PROMPT_DELAY_MS"] = String(promptDelayMilliseconds)
        }
        if let promptProgressDurationMilliseconds {
            fixtureEnvironment["GNOSTIC_ACP_FIXTURE_PROMPT_PROGRESS_DURATION_MS"] = String(promptProgressDurationMilliseconds)
        }
        if let promptProgressIntervalMilliseconds {
            fixtureEnvironment["GNOSTIC_ACP_FIXTURE_PROMPT_PROGRESS_INTERVAL_MS"] = String(promptProgressIntervalMilliseconds)
        }
        if let promptStartedFile {
            fixtureEnvironment["GNOSTIC_ACP_FIXTURE_PROMPT_STARTED_FILE"] = promptStartedFile.path
        }
        if let cancellationFile {
            fixtureEnvironment["GNOSTIC_ACP_FIXTURE_CANCEL_FILE"] = cancellationFile.path
        }
        if let wireLogFile {
            fixtureEnvironment["GNOSTIC_ACP_FIXTURE_WIRE_LOG_FILE"] = wireLogFile.path
        }
        if let promptRequestFile {
            fixtureEnvironment["GNOSTIC_ACP_FIXTURE_PROMPT_REQUEST_FILE"] = promptRequestFile.path
        }
        let encodedEnvironment = try JSONEncoder().encode(fixtureEnvironment)
        return [
            "command": .string("/usr/bin/node"),
            "args": .string(try #require(String(data: JSONEncoder().encode([fixturePath]), encoding: .utf8))),
            "env": .string(try #require(String(data: encodedEnvironment, encoding: .utf8))),
        ]
    }

    private func requireDead(pid: pid_t, message: String) async throws {
        for _ in 0..<40 where kill(pid, 0) == 0 {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(kill(pid, 0) != 0, Comment(rawValue: message))
    }

    private func makeTemporaryStateHome() throws -> TemporaryStateHome {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-acp-test-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let originalValue = getenv("GNOSTIC_STATE_HOME").map { String(cString: $0) }
        guard setenv("GNOSTIC_STATE_HOME", url.path, 1) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        return TemporaryStateHome(url: url, previousValue: originalValue)
    }

    private struct TemporaryStateHome {
        let url: URL
        let previousValue: String?

        func cleanup() {
            if let previousValue {
                _ = setenv("GNOSTIC_STATE_HOME", previousValue, 1)
            } else {
                _ = unsetenv("GNOSTIC_STATE_HOME")
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - ADR 0019 section 5 and ADR 0021 Turn semantics

    /// The ordered wire events the fixture recorded, for example
    /// `["prompt 4", "cancel_request 4"]`.
    private func wireEvents(_ file: URL) -> [String] {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline).map(String.init)
    }

    private func waitForWireEvents(_ file: URL, count: Int) async throws {
        for _ in 0..<500 where wireEvents(file).count < count {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Runs `body`, or reports `nil` when it has not settled within `seconds`.
    /// A regression that waits on the fixture instead of cancelling fails fast
    /// rather than holding the suite for the fixture's own deadline.
    private func settle<T: Sendable>(
        _ task: Task<T, any Error>,
        seconds: Int = 8
    ) async -> Result<T, any Error>? {
        let box = SettleBox<T>()
        let watcher = Task {
            do { await box.set(.success(try await task.value)) } catch { await box.set(.failure(error)) }
        }
        for _ in 0..<(seconds * 100) {
            if let result = await box.value { return result }
            try? await Task.sleep(for: .milliseconds(10))
        }
        watcher.cancel()
        return await box.value
    }

    private actor SettleBox<T: Sendable> {
        private(set) var value: Result<T, any Error>?

        func set(_ result: Result<T, any Error>) { value = result }
    }

    @Test("cancelling while insertion is pending sends $/cancel_request and a -32800 answer ends the Turn cancelled without session/cancel")
    @MainActor
    func cancelRequestPreventsInsertion() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let wireLog = stateHome.url.appendingPathComponent("wire.log")
        let backend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url, wireLogFile: wireLog),
            timelines: [.init(id: timelineID, title: "Cancel before insertion")]
        )
        let turn = Task {
            try await backend.runTurn(
                .init(timelineID: timelineID, message: "[fixture:hold-before-insertion]", clientTurnID: "hold-1"),
                updates: RecordingUpdateSink()
            )
        }
        try await waitForWireEvents(wireLog, count: 1)
        await backend.cancelTurn(timelineID: timelineID, clientTurnID: "hold-1")

        let outcome = await settle(turn)
        guard case let .failure(error)? = outcome, case AscendantBackendError.cancelled = error else {
            Issue.record("Expected the Turn to end cancelled, observed \(String(describing: outcome)).")
            await backend.shutdown()
            return
        }
        let events = wireEvents(wireLog)
        let promptID = try #require(events.first?.split(separator: " ").last.map(String.init))
        #expect(events == ["prompt \(promptID)", "cancel_request \(promptID)"])
        await backend.shutdown()
    }

    @Test("a success answer to $/cancel_request is followed by session/cancel")
    @MainActor
    func insertedDespiteCancelRequestIsFollowedBySessionCancel() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let wireLog = stateHome.url.appendingPathComponent("wire.log")
        let backend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url, wireLogFile: wireLog),
            timelines: [.init(id: timelineID, title: "Inserted despite cancel request")]
        )
        let turn = Task {
            try await backend.runTurn(
                .init(
                    timelineID: timelineID,
                    message: "[fixture:hold-before-insertion] [fixture:insert-despite-cancel-request] [fixture:wait]",
                    clientTurnID: "insert-anyway-1"
                ),
                updates: RecordingUpdateSink()
            )
        }
        try await waitForWireEvents(wireLog, count: 1)
        await backend.cancelTurn(timelineID: timelineID, clientTurnID: "insert-anyway-1")

        let outcome = await settle(turn)
        guard case let .failure(error)? = outcome, case AscendantBackendError.cancelled = error else {
            Issue.record("Expected the Turn to end cancelled, observed \(String(describing: outcome)).")
            await backend.shutdown()
            return
        }
        try await waitForWireEvents(wireLog, count: 3)
        let events = wireEvents(wireLog)
        let promptID = try #require(events.first?.split(separator: " ").last.map(String.init))
        #expect(events.count == 3)
        #expect(events.first == "prompt \(promptID)")
        #expect(events.dropFirst().first == "cancel_request \(promptID)")
        #expect(events.last?.hasPrefix("session_cancel ") == true)
        await backend.shutdown()
    }

    /// Runs one Turn the way `TurnService` does: through the coordinator, whose
    /// cancel closure reaches the backend before the coordinator cancels the
    /// Turn's task.
    @MainActor
    private func coordinatedTurn(
        _ coordinator: AscendantTurnCoordinator,
        backend: ACPAscendantBackend,
        timelineID: UUID,
        message: String,
        clientTurnID: String,
        updates: RecordingUpdateSink = RecordingUpdateSink()
    ) -> Task<AscendantTurnResult, any Error> {
        Task {
            try await coordinator.execute(
                AscendantTurnRequest(message: message, timelineID: timelineID, clientTurnID: clientTurnID),
                ascendantID: UUID(),
                cancel: { await backend.cancelTurn(timelineID: timelineID, clientTurnID: clientTurnID) }
            ) {
                try await backend.runTurn(
                    .init(timelineID: timelineID, message: message, clientTurnID: clientTurnID),
                    updates: updates
                )
            }
        }
    }

    @Test("a coordinator cancel that finds the prompt inserted anyway sends $/cancel_request, then session/cancel")
    @MainActor
    func coordinatorCancelFollowsASuccessAnswerWithSessionCancel() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let wireLog = stateHome.url.appendingPathComponent("wire.log")
        let backend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url, wireLogFile: wireLog),
            timelines: [.init(id: timelineID, title: "Coordinator cancel, inserted")]
        )
        let coordinator = AscendantTurnCoordinator()
        let turn = coordinatedTurn(
            coordinator, backend: backend, timelineID: timelineID,
            message: "[fixture:hold-before-insertion] [fixture:insert-despite-cancel-request] [fixture:wait]",
            clientTurnID: "coordinated-insert-1"
        )
        try await waitForWireEvents(wireLog, count: 1)
        #expect(await coordinator.cancelTurn(timelineID: timelineID, clientTurnID: "coordinated-insert-1"))

        let outcome = await settle(turn)
        guard case let .failure(error)? = outcome, case AscendantTurnError.cancelled = error else {
            Issue.record("Expected the Turn to end cancelled, observed \(String(describing: outcome)).")
            await backend.shutdown()
            return
        }
        try await waitForWireEvents(wireLog, count: 3)
        let events = wireEvents(wireLog)
        let promptID = try #require(events.first?.split(separator: " ").last.map(String.init))
        #expect(events.count == 3)
        #expect(events.first == "prompt \(promptID)")
        #expect(events.dropFirst().first == "cancel_request \(promptID)")
        #expect(events.last?.hasPrefix("session_cancel ") == true)
        await backend.shutdown()
    }

    @Test("a coordinator cancel answered -32800 ends the Turn cancelled with no session/cancel")
    @MainActor
    func coordinatorCancelAnsweredRequestCancelledSendsNoSessionCancel() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let wireLog = stateHome.url.appendingPathComponent("wire.log")
        let backend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url, wireLogFile: wireLog),
            timelines: [.init(id: timelineID, title: "Coordinator cancel, not inserted")]
        )
        let coordinator = AscendantTurnCoordinator()
        let turn = coordinatedTurn(
            coordinator, backend: backend, timelineID: timelineID,
            message: "[fixture:hold-before-insertion]", clientTurnID: "coordinated-hold-1"
        )
        try await waitForWireEvents(wireLog, count: 1)
        #expect(await coordinator.cancelTurn(timelineID: timelineID, clientTurnID: "coordinated-hold-1"))

        let outcome = await settle(turn)
        guard case let .failure(error)? = outcome, case AscendantTurnError.cancelled = error else {
            Issue.record("Expected the Turn to end cancelled, observed \(String(describing: outcome)).")
            await backend.shutdown()
            return
        }
        // Give a misbehaving backend time to send the follow-up before asserting silence.
        try await Task.sleep(for: .milliseconds(500))
        let events = wireEvents(wireLog)
        let promptID = try #require(events.first?.split(separator: " ").last.map(String.init))
        #expect(events == ["prompt \(promptID)", "cancel_request \(promptID)"])
        await backend.shutdown()
    }

    /// Starts a distinct Turn on a Timeline whose earlier Turn ended, and
    /// returns how the coordinator answered it.
    @MainActor
    private func nextTurnError(
        _ coordinator: AscendantTurnCoordinator,
        backend: ACPAscendantBackend,
        timelineID: UUID
    ) async -> AscendantTurnError? {
        let next = coordinatedTurn(
            coordinator, backend: backend, timelineID: timelineID, message: "next Turn", clientTurnID: "next-1"
        )
        guard case let .failure(error)? = await settle(next, seconds: 4) else { return nil }
        return error as? AscendantTurnError
    }

    @Test("a Runtime that ignores session/cancel cannot hold the Timeline busy past the cancellation bound")
    @MainActor
    func runtimeIgnoringSessionCancelReleasesTheTimeline() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let wireLog = stateHome.url.appendingPathComponent("wire.log")
        let backend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url, wireLogFile: wireLog),
            timelines: [.init(id: timelineID, title: "Runtime ignores cancel")],
            cancellationSettleSeconds: 1
        )
        let coordinator = AscendantTurnCoordinator()
        let sink = RecordingUpdateSink()
        let turn = coordinatedTurn(
            coordinator, backend: backend, timelineID: timelineID,
            message: "[fixture:ignore-cancel]", clientTurnID: "ignore-cancel-1", updates: sink
        )
        try await waitForWireEvents(wireLog, count: 1)
        // Cancel only once the prompt's answer reached the backend, so the
        // cancel finds the prompt inserted and sends `session/cancel` alone.
        try await sink.waitForInsertion()
        #expect(await coordinator.cancelTurn(timelineID: timelineID, clientTurnID: "ignore-cancel-1"))

        // The Runtime never reports `idle`. The Turn ends without claiming it
        // stopped, and the failure retires the backend.
        let outcome = await settle(turn, seconds: 6)
        guard case let .failure(error)? = outcome, case AscendantTurnError.lifecycleUnusable = error else {
            Issue.record("Expected a lifecycleUnusable end within the bound, observed \(String(describing: outcome)).")
            await backend.shutdown()
            return
        }
        let events = wireEvents(wireLog)
        #expect(events.count == 2)
        #expect(events.first?.hasPrefix("prompt ") == true)
        #expect(events.last?.hasPrefix("session_cancel ") == true)

        // The Timeline is free: the next Turn is rejected by the retired
        // backend, not by `timelineBusy`, and nothing reaches the Runtime.
        let next = await nextTurnError(coordinator, backend: backend, timelineID: timelineID)
        guard case .lifecycleUnusable? = next else {
            Issue.record("Expected the next Turn to meet the retired backend, observed \(String(describing: next)).")
            await backend.shutdown()
            return
        }
        #expect(wireEvents(wireLog) == events)
        await backend.shutdown()
    }

    @Test("a Runtime that answers the prompt late still gets a full bound to idle after session/cancel")
    @MainActor
    func lateAnswerGetsAFreshBoundFromSessionCancel() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let wireLog = stateHome.url.appendingPathComponent("wire.log")
        // The answer follows the cancel by 1.5 s and the idle follows
        // `session/cancel` by 1 s: 2.5 s after the cancel, past a 2 s bound that
        // started at the cancel, and inside one that starts at `session/cancel`.
        let backend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url, wireLogFile: wireLog),
            timelines: [.init(id: timelineID, title: "Late answer, late idle")],
            cancellationSettleSeconds: 2
        )
        let coordinator = AscendantTurnCoordinator()
        let sink = RecordingUpdateSink()
        let turn = coordinatedTurn(
            coordinator, backend: backend, timelineID: timelineID,
            message: "[fixture:answer-late] [fixture:wait] [fixture:idle-late]",
            clientTurnID: "late-answer-1", updates: sink
        )
        // The Runtime's progress reaches the backend while the prompt is still
        // unanswered. Any update after the cancel ends the Turn, so the cancel
        // waits until the Runtime has nothing in flight.
        try await sink.waitForUpdate()
        #expect(await coordinator.cancelTurn(timelineID: timelineID, clientTurnID: "late-answer-1"))

        let outcome = await settle(turn, seconds: 8)
        guard case let .failure(error)? = outcome, case AscendantTurnError.cancelled = error else {
            Issue.record("Expected the Runtime's late idle to end the Turn cancelled, observed \(String(describing: outcome)).")
            await backend.shutdown()
            return
        }
        let events = wireEvents(wireLog)
        #expect(events.count == 3)
        #expect(events.first?.hasPrefix("prompt ") == true)
        #expect(events.dropFirst().first?.hasPrefix("cancel_request ") == true)
        #expect(events.last?.hasPrefix("session_cancel ") == true)
        await backend.shutdown()
    }

    @Test("a Runtime that never answers $/cancel_request ends the Turn insertionUnknown within the cancellation bound")
    @MainActor
    func unansweredCancelRequestEndsInsertionUnknown() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let wireLog = stateHome.url.appendingPathComponent("wire.log")
        let backend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url, wireLogFile: wireLog),
            timelines: [.init(id: timelineID, title: "Runtime ignores cancel request")],
            cancellationSettleSeconds: 1
        )
        let coordinator = AscendantTurnCoordinator()
        let turn = coordinatedTurn(
            coordinator, backend: backend, timelineID: timelineID,
            message: "[fixture:hold-before-insertion] [fixture:ignore-cancel-request]",
            clientTurnID: "unanswered-cancel-1"
        )
        try await waitForWireEvents(wireLog, count: 1)
        #expect(await coordinator.cancelTurn(timelineID: timelineID, clientTurnID: "unanswered-cancel-1"))

        let outcome = await settle(turn, seconds: 6)
        guard case let .failure(error)? = outcome, case AscendantTurnError.insertionUnknown = error else {
            Issue.record("Expected insertionUnknown within the bound, observed \(String(describing: outcome)).")
            await backend.shutdown()
            return
        }
        let events = wireEvents(wireLog)
        let promptID = try #require(events.first?.split(separator: " ").last.map(String.init))
        #expect(events == ["prompt \(promptID)", "cancel_request \(promptID)"])
        let next = await nextTurnError(coordinator, backend: backend, timelineID: timelineID)
        guard case .lifecycleUnusable? = next else {
            Issue.record("Expected the next Turn to meet the retired backend, observed \(String(describing: next)).")
            await backend.shutdown()
            return
        }
        await backend.shutdown()
    }

    @Test("a prompt that times out without a response is insertionUnknown and is not sent again")
    @MainActor
    func promptTimeoutIsInsertionUnknown() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let promptRequests = stateHome.url.appendingPathComponent("prompt-requests.txt")
        let backend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url, promptRequestFile: promptRequests),
            timelines: [.init(id: timelineID, title: "Prompt timeout")],
            promptTimeoutSeconds: 1
        )
        let turn = Task {
            try await backend.runTurn(
                .init(timelineID: timelineID, message: "[fixture:drop-prompt-response]", clientTurnID: "timeout-1"),
                updates: RecordingUpdateSink()
            )
        }
        let outcome = await settle(turn, seconds: 8)
        guard case let .failure(error)? = outcome, case let AscendantBackendError.insertionUnknown(failure) = error else {
            Issue.record("Expected insertionUnknown, observed \(String(describing: outcome)).")
            await backend.shutdown()
            return
        }
        // The timeout also marks the connection unusable, so the host retires it.
        #expect(failure?.code == "acpTransportUnusable")
        #expect(wireEvents(promptRequests).count == 1)
        await backend.shutdown()
    }

    /// Reads the Timeline journal each time the backend forwards assistant text,
    /// so the test sees whether the update was already durable.
    private actor DurabilityProbeSink: AscendantBackendUpdateSink {
        private let store: TimelineJournalStore
        private let timelineID: UUID
        private(set) var forwarded: [String] = []
        private(set) var notYetDurable: [String] = []

        init(store: TimelineJournalStore, timelineID: UUID) {
            self.store = store
            self.timelineID = timelineID
        }

        func append(_ update: AscendantBackendUpdate) async throws {
            guard update.kind == .assistantText, let text = update.text else { return }
            forwarded.append(text)
            let records = try await store.journal(for: timelineID).replay()
            let durable = records.contains { record in
                if case let .acpUpdate(_, journaled) = record.payload,
                   case let .agentMessageChunk(chunk) = journaled.update,
                   case let .text(content) = chunk.content {
                    return content.text == text
                }
                return false
            }
            if !durable { notYetDurable.append(text) }
        }
    }

    @Test("an ACP update is durable in the Timeline journal before the backend forwards it")
    @MainActor
    func acpUpdateIsDurableBeforeForwarding() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let runtimeID = UUID()
        let store = TimelineJournalStore(directoryURL: stateHome.url.appendingPathComponent("journals"))
        try await store.ensureTimelineCreated(timelineID: timelineID, title: "Durable", runtimeInstanceID: runtimeID, attachments: [])
        let instance = try backend(
            settings: fixtureSettings(stateHome: stateHome.url),
            timelines: [NodeManifest.Timeline(id: timelineID, title: "Durable")],
            ascendantID: runtimeID,
            optionalCapabilities: [TimelineJournalRecorder(journals: store)]
        )
        let sink = DurabilityProbeSink(store: store, timelineID: timelineID)
        _ = try await instance.runTurn(.init(timelineID: timelineID, message: "durable first", clientTurnID: "durable-1"), updates: sink)

        let forwarded = await sink.forwarded
        let notYetDurable = await sink.notYetDurable
        #expect(forwarded.count == 2, "observed \(forwarded)")
        #expect(notYetDurable.isEmpty, "Forwarded before it was durable: \(notYetDurable)")
        await instance.shutdown()
    }

    @Test("cancelling after insertion sends session/cancel and never $/cancel_request")
    @MainActor
    func cancelAfterInsertionSendsSessionCancelOnly() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let wireLog = stateHome.url.appendingPathComponent("wire.log")
        let promptStarted = stateHome.url.appendingPathComponent("prompt-started")
        let backend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url, promptStartedFile: promptStarted, wireLogFile: wireLog),
            timelines: [.init(id: timelineID, title: "Cancel after insertion")]
        )
        let sink = RecordingUpdateSink()
        let turn = Task {
            try await backend.runTurn(
                .init(timelineID: timelineID, message: "[fixture:wait]", clientTurnID: "after-insertion-1"),
                updates: sink
            )
        }
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: promptStarted.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        // Cancel only once the prompt response reached the backend, so the
        // cancel finds the prompt inserted.
        try await sink.waitForInsertion()
        await backend.cancelTurn(timelineID: timelineID, clientTurnID: "after-insertion-1")

        let outcome = await settle(turn)
        guard case let .failure(error)? = outcome, case AscendantBackendError.cancelled = error else {
            Issue.record("Expected the Turn to end cancelled, observed \(String(describing: outcome)).")
            await backend.shutdown()
            return
        }
        let events = wireEvents(wireLog)
        #expect(events.count == 2)
        #expect(events.first?.hasPrefix("prompt ") == true)
        #expect(events.last?.hasPrefix("session_cancel ") == true)
        await backend.shutdown()
    }

    @Test("a Turn cancelled before dispatch never sends session/prompt")
    @MainActor
    func turnCancelledBeforeDispatchSendsNoPrompt() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let wireLog = stateHome.url.appendingPathComponent("wire.log")
        let backend = try backend(
            settings: fixtureSettings(
                stateHome: stateHome.url,
                initializeDelayMilliseconds: 600,
                wireLogFile: wireLog
            ),
            timelines: [.init(id: timelineID, title: "Cancel before dispatch")]
        )
        let turn = Task {
            try await backend.runTurn(
                .init(timelineID: timelineID, message: "never sent", clientTurnID: "before-dispatch-1"),
                updates: RecordingUpdateSink()
            )
        }
        // The Runtime is still initializing, so the prompt has not been dispatched.
        try await Task.sleep(for: .milliseconds(150))
        turn.cancel()

        let outcome = await settle(turn, seconds: 15)
        if case .success? = outcome { Issue.record("A Turn cancelled before dispatch completed.") }
        #expect(outcome != nil)
        // Give a misbehaving backend time to dispatch before asserting silence.
        try await Task.sleep(for: .milliseconds(900))
        #expect(wireEvents(wireLog).isEmpty)
        await backend.shutdown()
    }

    @Test("a prompt response lost to a Runtime crash is insertionUnknown and the Turn is never dispatched again")
    @MainActor
    func lostPromptResponseIsInsertionUnknown() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let ascendantID = UUID()
        let timelineID = UUID()
        let promptRequests = stateHome.url.appendingPathComponent("prompt-requests.txt")
        let configuration = AscendantBackendConfiguration(
            kind: ACPAscendantBackend.kind,
            settings: try fixtureSettings(stateHome: stateHome.url, crashOnPrompt: true, promptRequestFile: promptRequests)
        )
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "acp-lost-prompt-\(UUID().uuidString.lowercased())"),
            node: .init(id: UUID()),
            ascendants: [.init(id: ascendantID, name: "Lost response", defaultTimelineID: timelineID, backend: configuration)],
            timelines: [.init(id: timelineID, title: "Lost response", operatingAscendantID: ascendantID, project: .local(stateHome.url.path))]
        )
        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.registerBackend(
            kind: ACPAscendantBackend.kind,
            settings: ACPAscendantBackend.settingsSchema
        ) { ascendant, backendConfiguration, services, timelines in
            try ACPAscendantBackend(
                ascendant: ascendant,
                configuration: backendConfiguration,
                services: services,
                timelines: timelines
            )
        }
        let journalDirectory = stateHome.url.appendingPathComponent("timeline-journals")
        let request = AscendantTurnRequest(message: "lose the response", timelineID: timelineID, clientTurnID: "lost-response-1")
        var runtime = try await NodeRuntime(
            plan: manifest.compileLaunchPlan(), adapters: adapters, timelineJournalDirectory: journalDirectory
        )
        try await runtime.start()

        for attempt in 1...2 {
            do {
                _ = try await runtime.turn(request)
                Issue.record("Attempt \(attempt) unexpectedly returned a result.")
            } catch let error as AscendantTurnError {
                #expect(error.reasonCode == "insertionUnknown", "attempt \(attempt) observed \(error.reasonCode)")
                #expect(!error.retryable)
            }
        }
        await runtime.shutdown()

        // A restarted Node answers from the Timeline journal and still sends nothing.
        runtime = try await NodeRuntime(
            plan: manifest.compileLaunchPlan(), adapters: adapters, timelineJournalDirectory: journalDirectory
        )
        try await runtime.start()
        do {
            _ = try await runtime.turn(request)
            Issue.record("The restarted Node unexpectedly returned a result.")
        } catch let error as AscendantTurnError {
            #expect(error.reasonCode == "insertionUnknown", "after restart observed \(error.reasonCode)")
        }
        await runtime.shutdown()

        #expect(wireEvents(promptRequests).count == 1, "session/prompt was sent \(wireEvents(promptRequests).count) times")
        let nodeDirectory = journalDirectory.appendingPathComponent(manifest.node.id.uuidString.lowercased())
        let fileURL = TimelineJournalStore.fileURL(for: timelineID, in: nodeDirectory)
        let completions = try AppendOnlyEventLog<TimelineJournalRecord>(fileURL: fileURL)
            .scan().records.map(\.payload.payload)
            .compactMap { payload -> TimelineTurnTerminalOutcome? in
                if case let .turnCompleted("lost-response-1", outcome, _) = payload { return outcome }
                return nil
            }
        #expect(completions == [.insertionUnknown])
    }

    @Test("an idle update without a stop reason ends the Turn endedUnspecified in the journal")
    @MainActor
    func idleWithoutStopReasonIsEndedUnspecified() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let ascendantID = UUID()
        let timelineID = UUID()
        let configuration = AscendantBackendConfiguration(
            kind: ACPAscendantBackend.kind,
            settings: try fixtureSettings(stateHome: stateHome.url)
        )
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "acp-unspecified-\(UUID().uuidString.lowercased())"),
            node: .init(id: UUID()),
            ascendants: [.init(id: ascendantID, name: "Unspecified", defaultTimelineID: timelineID, backend: configuration)],
            timelines: [.init(id: timelineID, title: "Unspecified", operatingAscendantID: ascendantID, project: .local(stateHome.url.path))]
        )
        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.registerBackend(
            kind: ACPAscendantBackend.kind,
            settings: ACPAscendantBackend.settingsSchema
        ) { ascendant, backendConfiguration, services, timelines in
            try ACPAscendantBackend(
                ascendant: ascendant,
                configuration: backendConfiguration,
                services: services,
                timelines: timelines
            )
        }
        let journalDirectory = stateHome.url.appendingPathComponent("timeline-journals")
        let runtime = try await NodeRuntime(
            plan: manifest.compileLaunchPlan(), adapters: adapters, timelineJournalDirectory: journalDirectory
        )
        try await runtime.start()

        let result = try await runtime.turn(.init(
            message: "[fixture:idle-without-stop-reason]",
            timelineID: timelineID,
            clientTurnID: "unspecified-1"
        ))
        #expect(result.text.contains("reply"))
        await runtime.shutdown()

        let nodeDirectory = journalDirectory.appendingPathComponent(manifest.node.id.uuidString.lowercased())
        let fileURL = TimelineJournalStore.fileURL(for: timelineID, in: nodeDirectory)
        let completions = try AppendOnlyEventLog<TimelineJournalRecord>(fileURL: fileURL)
            .scan().records.map(\.payload.payload)
            .compactMap { payload -> TimelineTurnTerminalOutcome? in
                if case let .turnCompleted("unspecified-1", outcome, _) = payload { return outcome }
                return nil
            }
        #expect(completions == [.endedUnspecified])
    }

    @Test("a successful prompt response binds the Turn to the Runtime's messageId in the journal")
    @MainActor
    func promptResponseBindsTheRuntimeMessageID() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let ascendantID = UUID()
        let timelineID = UUID()
        let configuration = AscendantBackendConfiguration(
            kind: ACPAscendantBackend.kind,
            settings: try fixtureSettings(stateHome: stateHome.url)
        )
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "acp-message-binding-\(UUID().uuidString.lowercased())"),
            node: .init(id: UUID()),
            ascendants: [.init(id: ascendantID, name: "Binding", defaultTimelineID: timelineID, backend: configuration)],
            timelines: [.init(id: timelineID, title: "Binding", operatingAscendantID: ascendantID, project: .local(stateHome.url.path))]
        )
        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.registerBackend(
            kind: ACPAscendantBackend.kind,
            settings: ACPAscendantBackend.settingsSchema
        ) { ascendant, backendConfiguration, services, timelines in
            try ACPAscendantBackend(
                ascendant: ascendant,
                configuration: backendConfiguration,
                services: services,
                timelines: timelines
            )
        }
        let journalDirectory = stateHome.url.appendingPathComponent("timeline-journals")
        let runtime = try await NodeRuntime(
            plan: manifest.compileLaunchPlan(), adapters: adapters, timelineJournalDirectory: journalDirectory
        )
        try await runtime.start()
        _ = try await runtime.turn(.init(message: "bind me", timelineID: timelineID, clientTurnID: "bound-1"))
        await runtime.shutdown()

        let nodeDirectory = journalDirectory.appendingPathComponent(manifest.node.id.uuidString.lowercased())
        let fileURL = TimelineJournalStore.fileURL(for: timelineID, in: nodeDirectory)
        let completions = try AppendOnlyEventLog<TimelineJournalRecord>(fileURL: fileURL)
            .scan().records.map(\.payload.payload)
            .compactMap { payload -> String? in
                if case let .turnCompleted("bound-1", _, messageID) = payload { return messageID }
                return nil
            }
        #expect(completions == ["fixture-user-1"])
    }

    private actor RecordingUpdateSink: AscendantBackendUpdateSink {
        private(set) var updates: [AscendantBackendUpdate] = []
        private(set) var boundMessageIDs: [String] = []

        func append(_ update: AscendantBackendUpdate) async throws {
            updates.append(update)
        }

        func bindMessage(_ messageID: String) async {
            boundMessageIDs.append(messageID)
        }

        /// Waits until the backend forwarded an update.
        func waitForUpdate() async throws {
            for _ in 0..<500 where updates.isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!updates.isEmpty, "The Runtime sent no update.")
        }

        /// Waits until the Runtime's success response for the prompt reached
        /// the backend, which records insertion before it binds the message.
        func waitForInsertion() async throws {
            for _ in 0..<500 where boundMessageIDs.isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!boundMessageIDs.isEmpty, "The prompt was not inserted.")
        }
    }
}

private actor RuntimeACPSubprocessClient {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private var pending: [ACPJSONRPCMessage] = []

    init(executableURL: URL, environment: [String: String]) throws {
        let process = Process()
        process.executableURL = executableURL
        process.environment = environment
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
    }

    func send<T: Encodable>(_ value: T) throws {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    func response(id: Int) throws -> ACPJSONRPCResponse {
        while true {
            if let index = pending.firstIndex(where: { message in
                if case let .response(response) = message { return response.id == .int(id) }
                return false
            }), case let .response(response) = pending.remove(at: index) {
                return response
            }
            let message = try readMessage()
            if case let .response(response) = message, response.id == .int(id) { return response }
            pending.append(message)
        }
    }

    func notification() throws -> ACPJSONRPCNotification {
        if let index = pending.firstIndex(where: { if case .notification = $0 { return true }; return false }),
           case let .notification(notification) = pending.remove(at: index) {
            return notification
        }
        while true {
            let message = try readMessage()
            if case let .notification(notification) = message { return notification }
            pending.append(message)
        }
    }

    func finish() {
        try? input.close()
        process.waitUntilExit()
        try? output.close()
    }

    func terminate() {
        try? input.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        try? output.close()
    }

    func terminationStatus() -> Int32 { process.terminationStatus }

    private func readMessage() throws -> ACPJSONRPCMessage {
        var bytes = Data()
        while true {
            guard let byte = try output.read(upToCount: 1), !byte.isEmpty else {
                throw RuntimeACPSubprocessClientError.endOfFile
            }
            if byte[0] == 0x0A { break }
            bytes.append(byte)
        }
        return try JSONDecoder().decode(ACPJSONRPCMessage.self, from: bytes)
    }
}

private enum RuntimeACPSubprocessClientError: Error {
    case endOfFile
}
