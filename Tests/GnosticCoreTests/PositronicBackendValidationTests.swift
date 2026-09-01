// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
@testable import GnosticCore
import PKContracts
import PositronicKit
import Testing

@Suite("Positronic backend semantic validation")
struct PositronicBackendValidationTests {
    @Test("accepts an empty envelope as the intentional unconfigured state")
    @MainActor
    func acceptsUnconfiguredState() async throws {
        let adapter = try await makeAdapter(backend: .init(kind: "positronic"))

        try adapter.validateConfiguration()
    }

    @Test("Timeline mutation serialization keeps mutation and projection together")
    @MainActor
    func timelineMutationSerializationIsDeterministic() async throws {
        let gate = TimelineMutationGate()
        let probe = RenameInterleavingProbe()

        let first = Task { @MainActor in
            try await gate.withExclusiveAccess {
                await probe.mutate(title: "First")
                await probe.waitForFirstRelease()
                return await probe.title
            }
        }
        await probe.waitUntilFirstMutation()

        let second = Task { @MainActor in
            await probe.markSecondAttempted()
            return try await gate.withExclusiveAccess {
                await probe.mutate(title: "Second")
                return await probe.title
            }
        }
        await probe.waitUntilSecondAttempted()
        while await gate.waitingCount == 0 {
            await Task.yield()
        }
        #expect(await probe.titles == ["First"])

        await probe.releaseFirst()
        #expect(try await first.value == "First")
        #expect(try await second.value == "Second")
        #expect(await probe.titles == ["First", "Second"])
    }

    @Test("canceled queued Timeline mutations never execute")
    @MainActor
    func canceledQueuedMutationDoesNotExecute() async throws {
        let gate = TimelineMutationGate()
        let probe = RenameInterleavingProbe()

        let first = Task { @MainActor in
            try await gate.withExclusiveAccess {
                await probe.mutate(title: "First")
                await probe.waitForFirstRelease()
                return await probe.title
            }
        }
        await probe.waitUntilFirstMutation()

        let queued = Task { @MainActor in
            do {
                return try await gate.withExclusiveAccess {
                    await probe.mutate(title: "Canceled")
                    return await probe.title
                }
            } catch {
                await probe.markQueuedCanceled()
                throw error
            }
        }
        while await gate.waitingCount == 0 {
            await Task.yield()
        }
        queued.cancel()
        var canceledBeforeRelease = false
        for _ in 0 ..< 1_000 {
            if await probe.queuedCanceled {
                canceledBeforeRelease = true
                break
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(canceledBeforeRelease)
        #expect(await probe.titles == ["First"])
        await probe.releaseFirst()

        #expect(try await first.value == "First")
        await #expect(throws: CancellationError.self) {
            _ = try await queued.value
        }
        #expect(await probe.titles == ["First"])
    }

    @Test("accepts a valid hosted provider configuration")
    @MainActor
    func acceptsValidConfiguration() async throws {
        let backend = makeBackend()
        let adapter = try await makeAdapter(backend: backend)

        try adapter.validateConfiguration()
    }

    @Test("rejects an unknown provider")
    @MainActor
    func rejectsUnknownProvider() async throws {
        let adapter = try await makeAdapter(backend: makeBackend(provider: "unknown"))

        #expect(throws: AscendantBackendError.self) {
            try adapter.validateConfiguration()
        }
    }

    @Test("rejects a missing hosted-provider API key")
    @MainActor
    func rejectsMissingAPIKey() async throws {
        let adapter = try await makeAdapter(backend: makeBackend(apiKey: nil))

        do {
            try adapter.validateConfiguration()
            Issue.record("The Positronic adapter accepted a missing API key.")
        } catch let error as AscendantBackendError {
            #expect(error.reasonCode == "invalidConfiguration")
            #expect(error.localizedDescription.contains("apiKey"))
        }
    }

    @Test("rejects an empty primary model")
    @MainActor
    func rejectsEmptyModel() async throws {
        let adapter = try await makeAdapter(backend: makeBackend(model: ""))

        do {
            try adapter.validateConfiguration()
            Issue.record("The Positronic adapter accepted an empty primary model.")
        } catch let error as AscendantBackendError {
            #expect(error.reasonCode == "invalidConfiguration")
            #expect(error.localizedDescription.contains("model"))
        }
    }

    @Test("rejects an empty utility model")
    @MainActor
    func rejectsEmptyUtilityModel() async throws {
        var backend = makeBackend()
        backend.settings["utilityModel"] = .string("")
        let adapter = try await makeAdapter(backend: backend)

        do {
            try adapter.validateConfiguration()
            Issue.record("The Positronic adapter accepted an empty utility model.")
        } catch let error as AscendantBackendError {
            #expect(error.localizedDescription.contains("utilityModel"))
        }
    }

    @Test("rejects a non-string fast model")
    @MainActor
    func rejectsNonStringFastModel() async throws {
        var backend = makeBackend()
        backend.settings["fastModel"] = .number(1)
        let adapter = try await makeAdapter(backend: backend)

        do {
            try adapter.validateConfiguration()
            Issue.record("The Positronic adapter accepted a non-string fast model.")
        } catch let error as AscendantBackendError {
            #expect(error.localizedDescription.contains("fastModel"))
        }
    }

    @Test("rejects malformed endpoints without exposing credential values")
    @MainActor
    func rejectsMalformedEndpointWithoutRedactionLeak() async throws {
        let secret = "endpoint-secret-value"
        let adapter = try await makeAdapter(
            backend: makeBackend(endpoint: "not-a-url?apiKey=\(secret)", apiKey: secret)
        )

        do {
            try adapter.validateConfiguration()
            Issue.record("The Positronic adapter accepted a malformed endpoint.")
        } catch let error as AscendantBackendError {
            #expect(error.reasonCode == "invalidConfiguration")
            #expect(error.localizedDescription.contains("endpoint"))
            #expect(!error.localizedDescription.contains(secret))
        }
    }

    @Test("startup rejects invalid Positronic semantics before publication")
    @MainActor
    func startupRejectsInvalidConfigurationBeforePublication() async throws {
        var manifest = NodeManifest.makeDefault(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "positronic-validation")
        )
        manifest.ascendants[0].backend = makeBackend(provider: "unknown")

        do {
            _ = try await NodeRuntime(plan: manifest.compileLaunchPlan())
            Issue.record("NodeRuntime published an invalid Positronic backend.")
        } catch let error as AscendantBackendError {
            #expect(error.reasonCode == "invalidConfiguration")
        }
    }

    @Test("reconstruction rejects a backend whose semantic validation fails")
    @MainActor
    func reconstructionValidatesBeforeActivation() async throws {
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000803")!
        let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000804")!
        let probe = ReconstructionValidationProbe()
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "positronic-reconstruction-validation"),
            node: .init(id: UUID(uuidString: "A21D0000-0000-4000-8000-000000000805")!),
            ascendants: [.init(id: ascendantID, name: "Validated", defaultTimelineID: timelineID, kind: "validation-fixture")],
            timelines: [.init(id: timelineID, title: "Default", operatingAscendantID: ascendantID)]
        )
        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.registerBackend(kind: "validation-fixture") { ascendant, _, _, timelines in
            let factoryNumber = await probe.nextFactory()
            return ReconstructionValidationBackend(
                ascendant: ascendant,
                timelines: timelines,
                failsValidation: factoryNumber == 2
            )
        }
        let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan(), adapters: adapters)
        try await runtime.start()
        defer { Task { @MainActor in await runtime.shutdown() } }

        do {
            _ = try await runtime.turn(.init(message: "quarantine", timelineID: timelineID, clientTurnID: "quarantine"))
            Issue.record("The lifecycle failure unexpectedly succeeded.")
        } catch {}

        do {
            _ = try await runtime.turn(.init(message: "reconstruct", timelineID: timelineID, clientTurnID: "reconstruct"))
            Issue.record("The invalid reconstruction candidate was activated.")
        } catch {}

        #expect(await probe.factoryCount == 2)
        #expect(await runtime.backendHealth(for: ascendantID) == .failed)
    }

    private func makeAdapter(
        backend: NodeManifest.BackendConfiguration
    ) async throws -> PositronicAscendantAdapter {
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000801")!
        let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000802")!
        let ascendant = NodeManifest.Ascendant(
            id: ascendantID,
            name: "Validated Ascendant",
            defaultTimelineID: timelineID,
            backend: backend
        )
        let timeline = NodeManifest.Timeline(
            id: timelineID,
            title: "Default",
            operatingAscendantID: ascendantID
        )
        return try await PositronicAscendantAdapter(
            ascendant: ascendant,
            backend: backend,
            services: .empty,
            timelines: [timeline],
            languageModel: UnconfiguredLLMService()
        )
    }

    private func makeBackend(
        provider: String = "Anthropic",
        endpoint: String? = "https://api.anthropic.com",
        model: String? = "claude-sonnet",
        apiKey: String? = "api-secret"
    ) -> NodeManifest.BackendConfiguration {
        var settings: [String: ManifestJSONValue] = ["provider": .string(provider)]
        if let endpoint { settings["endpoint"] = .string(endpoint) }
        if let model { settings["model"] = .string(model) }
        var secrets: [String: ManifestJSONValue] = [:]
        if let apiKey { secrets["apiKey"] = .string(apiKey) }
        return .init(kind: "positronic", settings: settings, secrets: secrets)
    }
}

private actor RenameInterleavingProbe {
    private(set) var titles: [String] = []
    private(set) var title = ""
    private(set) var queuedCanceled = false
    private var firstMutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var secondAttemptWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstMutated = false
    private var secondAttempted = false
    private var firstReleased = false

    func mutate(title: String) {
        self.title = title
        titles.append(title)
        if title == "First" {
            firstMutated = true
            firstMutationWaiters.forEach { $0.resume() }
            firstMutationWaiters.removeAll()
        }
    }

    func markSecondAttempted() {
        secondAttempted = true
        secondAttemptWaiters.forEach { $0.resume() }
        secondAttemptWaiters.removeAll()
    }

    func markQueuedCanceled() {
        queuedCanceled = true
    }

    func waitUntilFirstMutation() async {
        guard !firstMutated else { return }
        await withCheckedContinuation { firstMutationWaiters.append($0) }
    }

    func waitUntilSecondAttempted() async {
        guard !secondAttempted else { return }
        await withCheckedContinuation { secondAttemptWaiters.append($0) }
    }

    func waitForFirstRelease() async {
        guard !firstReleased else { return }
        await withCheckedContinuation { firstReleaseWaiters.append($0) }
    }

    func releaseFirst() {
        firstReleased = true
        firstReleaseWaiters.forEach { $0.resume() }
        firstReleaseWaiters.removeAll()
    }
}

private actor ReconstructionValidationProbe {
    private(set) var factoryCount = 0

    func nextFactory() -> Int {
        factoryCount += 1
        return factoryCount
    }
}

@MainActor
private final class ReconstructionValidationBackend: AscendantBackend {
    let identity: AscendantBackendIdentity
    private let timeline: AscendantBackendTimeline
    private let failsValidation: Bool

    init(
        ascendant: NodeManifest.Ascendant,
        timelines: [NodeManifest.Timeline],
        failsValidation: Bool
    ) {
        let now = Date()
        identity = .init(
            id: ascendant.id,
            name: ascendant.name,
            description: ascendant.description,
            privateTimelineID: ascendant.defaultTimelineID,
            primaryWorkspaceID: nil,
            lastActiveAt: now,
            createdAt: now,
            updatedAt: now
        )
        let configuration = timelines[0]
        timeline = .init(
            id: configuration.id,
            title: configuration.title,
            attachedWorkspaceIDs: configuration.attachments.map(\.workspaceID),
            ascendantID: ascendant.id,
            isArchived: false,
            isPrivate: false,
            createdAt: now,
            updatedAt: now
        )
        self.failsValidation = failsValidation
    }

    func validateConfiguration() throws {
        if failsValidation {
            throw AscendantBackendError.invalidConfiguration("reconstruction validation")
        }
    }

    func operatedTimelines() async throws -> [AscendantBackendTimeline] { [timeline] }

    func createTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        .init(
            id: id,
            title: title,
            attachedWorkspaceIDs: [],
            ascendantID: identity.id,
            isArchived: false,
            isPrivate: false,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    func removeTimeline(id: UUID) async {}

    func timeline(id: UUID) async throws -> any AscendantBackendTimelineSession {
        guard id == timeline.id else { throw AscendantBackendError.timelineNotFound(id) }
        return TimelineSession(id: id, backend: self)
    }

    @MainActor
    private final class TimelineSession: AscendantBackendTimelineSession {
        let id: UUID
        private let backend: ReconstructionValidationBackend

        init(id: UUID, backend: ReconstructionValidationBackend) {
            self.id = id
            self.backend = backend
        }

        func runTurn(
            _: AscendantBackendTimelineTurnRequest,
            updates _: any AscendantBackendUpdateSink
        ) async throws -> String {
            throw AscendantBackendError.lifecycleUnusable(.init(message: "fixture lifecycle failure"))
        }

        func rename(to title: String) async throws -> AscendantBackendTimeline {
            guard id == backend.timeline.id else { throw AscendantBackendError.timelineNotFound(id) }
            return .init(
                id: backend.timeline.id,
                title: title,
                attachedWorkspaceIDs: backend.timeline.attachedWorkspaceIDs,
                ascendantID: backend.timeline.ascendantID,
                isArchived: backend.timeline.isArchived,
                isPrivate: backend.timeline.isPrivate,
                createdAt: backend.timeline.createdAt,
                updatedAt: Date()
            )
        }
    }

    func cancel() async {}
    func shutdown() async {}
}
