// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation

/// Owns bounded Axoloty advertisement subscriptions for Gnostic object types.
@MainActor
public final class GnosticSubscription {
    /// The exact object types observed by this subscription.
    public static let objectTypes = [
        GnosticObjectType.ascendant,
        GnosticObjectType.timeline,
        GnosticObjectType.workspace,
    ]

    private let catalog: NetworkCatalog
    private let observe: @MainActor @Sendable (String) async throws -> AsyncStream<AdvertiseEventSnapshot>
    private let observeDeadvertise: @MainActor @Sendable () async -> AsyncStream<DeadvertiseEventSnapshot>
    private var scope: RuntimeEffectScope

    private enum LifecycleState {
        case stopped
        case starting
        case running
        case stopping
    }

    private var lifecycleState = LifecycleState.stopped
    private var lifecycleGeneration: UInt64 = 0
    private var startTask: Task<Void, Error>?
    private var stopTask: Task<Void, Never>?
    private var handles: [RuntimeEffectHandle] = []

    /// Creates a subscription owner using a scoped Axoloty observation operation.
    public init(
        catalog: NetworkCatalog,
        observe: @escaping @MainActor @Sendable (String) async throws -> AsyncStream<AdvertiseEventSnapshot>,
        observeDeadvertise: @escaping @MainActor @Sendable () async -> AsyncStream<DeadvertiseEventSnapshot>
    ) {
        self.catalog = catalog
        self.observe = observe
        self.observeDeadvertise = observeDeadvertise
        scope = try! RuntimeEffectScope(name: "gnostic-subscription")
    }

    /// Creates a subscription owner backed by an Axoloty communication manager.
    public convenience init(catalog: NetworkCatalog, communicationManager: CommunicationManager) {
        self.init(catalog: catalog, observe: { objectType in
            try await communicationManager.observeAdvertiseStream(withObjectType: objectType)
        }, observeDeadvertise: {
            await communicationManager.observeDeadvertiseStream()
        })
    }

    /// Starts one scoped subscription for each canonical Gnostic object type.
    public func start() async throws {
        switch lifecycleState {
        case .running:
            return
        case .starting:
            if let startTask { try await awaitStart(startTask) }
            return
        case .stopping:
            if let stopTask { await stopTask.value }
            try await start()
            return
        case .stopped:
            // A finished stop clears `stopTask` and `lifecycleState` in the
            // same isolated step, so `.stopped` never carries a pending stop.
            break
        }

        lifecycleState = .starting
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        let task = Task { @MainActor [self] in
            do {
                let acquired = try await self.performStart(in: self.scope)
                guard self.lifecycleState == .starting,
                      self.lifecycleGeneration == generation else {
                    for handle in acquired { _ = await handle.dispose() }
                    throw NodeRuntimeError.notRunning
                }
                self.handles = acquired
                self.lifecycleState = .running
            } catch {
                if self.lifecycleState == .starting,
                   self.lifecycleGeneration == generation {
                    self.lifecycleState = .stopped
                }
                throw error
            }
        }
        startTask = task
        // Only the originating caller forwards cancellation: a caller that
        // joined an in-flight start from the `.starting` branch must not
        // cancel work it did not initiate.
        try await withTaskCancellationHandler {
            try await awaitStart(task)
        } onCancel: {
            task.cancel()
        }
    }

    private func awaitStart(_ task: Task<Void, Error>) async throws {
        do {
            try await task.value
        } catch let error as RuntimeEffectScopeError {
            switch error {
            case .acquisitionClosed, .registrationRejected:
                throw NodeRuntimeError.notRunning
            case .invalidName, .invalidLabel, .invalidAdoption:
                throw error
            }
        }
    }

    private func performStart(in scope: RuntimeEffectScope) async throws -> [RuntimeEffectHandle] {
        let observe = self.observe
        let observeDeadvertise = self.observeDeadvertise
        let catalog = self.catalog
        return try await scope.withAcquisition { owner in
            var acquired: [RuntimeEffectHandle] = []
            let ascendant = try await observe(GnosticObjectType.ascendant)
            acquired.append(try await owner.task(label: "observe-ascendant") {
                for await event in ascendant { await catalog.ingest(event) }
            })

            let timeline = try await observe(GnosticObjectType.timeline)
            acquired.append(try await owner.task(label: "observe-timeline") {
                for await event in timeline { await catalog.ingest(event) }
            })

            let workspace = try await observe(GnosticObjectType.workspace)
            acquired.append(try await owner.task(label: "observe-workspace") {
                for await event in workspace { await catalog.ingest(event) }
            })

            let deadvertise = await observeDeadvertise()
            acquired.append(try await owner.task(label: "observe-deadvertise") {
                for await event in deadvertise { await catalog.ingest(event) }
            })
            return acquired
        }
    }

    /// Publishes one active discover request and ingests its correlated
    /// Resolve responses for a bounded window.
    ///
    /// The response stream remains open for the lifetime of the request, so
    /// the deadline task ends collection explicitly. Every response is
    /// retained through the same catalog path as an advertisement.
    public func discover(
        using communicationManager: CommunicationManager,
        timeout: Duration = .seconds(5)
    ) async {
        let stream = await communicationManager.publishDiscover(
            DiscoverEvent.with(objectTypes: Self.objectTypes)
        )
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [catalog] in
                for await response in stream {
                    await catalog.ingest(response)
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    /// Retrieves one public Workspace tool object per bounded query page.
    /// Querying stops at the owning provider's explicit empty page, at a page
    /// nobody answers within `timeout`, or at the fixed page ceiling; no
    /// response contains an unbounded collection.
    public func queryTools(
        using communicationManager: CommunicationManager,
        workspaceID: UUID,
        timeout: Duration = .seconds(5)
    ) async {
        for page in 0..<64 {
            let stream = await communicationManager.publishQuery(
                QueryEvent.with(
                    objectTypes: [GnosticObjectType.workspaceTool],
                    objectFilter: GnosticWorkspaceToolQuery.filter(workspaceID: workspaceID, page: page)
                ),
                timeout: timeout
            )
            let received = await receiveOne(from: stream, timeout: timeout)
            guard received else { break }
        }
    }

    /// Ingests the first response and reports whether it carried objects. An
    /// empty response is the provider's terminal page; a timeout means no
    /// provider answered.
    private func receiveOne(from stream: AsyncStream<ResponseEventSnapshot>, timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [catalog] in
                for await response in stream {
                    await catalog.ingest(response)
                    return !(response.objects ?? response.object.map { [$0] } ?? []).isEmpty
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    /// Cancels active subscription loops and waits for their scope cleanup,
    /// including the cleanup owned by a start that this stop cancelled, so
    /// no observation effect is live once it returns. The scope itself stays
    /// stable for restart. Concurrent callers join the same stop task. This is
    /// the deterministic ordering boundary for host shutdown; final scope
    /// disposal happens via ``disposeScope()``.
    public func stopAndWait() async {
        switch lifecycleState {
        case .stopped:
            if let stopTask { await stopTask.value }
            return
        case .stopping:
            if let stopTask { await stopTask.value }
            return
        case .starting, .running:
            break
        }

        lifecycleState = .stopping
        lifecycleGeneration &+= 1
        // Capture and clear synchronously: a fenced start that completes
        // after this point disposes its own newly acquired handles instead
        // of publishing them, so there is no double-dispose.
        let pendingStart = startTask
        pendingStart?.cancel()
        let toDispose = handles
        handles = []
        let task = Task { @MainActor [self] in
            // Await the cancelled start before reporting completion: it owns
            // disposal of anything it acquired past the generation fence, so
            // stop only means quiescence once it has settled. An `observe`
            // operation that ignores cancellation holds stop open, which is
            // the same contract violation TerminalTurnObserving documents.
            if let pendingStart { _ = await pendingStart.result }
            for handle in toDispose { _ = await handle.dispose() }
            if self.startTask == pendingStart { self.startTask = nil }
            // Clearing both in one isolated step keeps `.stopped` free of a
            // pending stop task for the `start()` fast path.
            if self.lifecycleState == .stopping {
                self.lifecycleState = .stopped
            }
            self.stopTask = nil
        }
        stopTask = task
        await task.value
    }

    /// Disposes the underlying scope after shutdown. Call only during final
    /// host cleanup; scope is not replaced after this point.
    public func disposeScope() async {
        if let stopTask { await stopTask.value }
        handles = []
        _ = await scope.dispose()
    }

    /// Gives a host scope one structural owner for this subscription's effects.
    /// The scope remains stable across stop/start cycles and is only disposed
    /// during host shutdown via ``disposeScope()``.
    func adopt(into parent: RuntimeEffectScope) async throws {
        _ = try await parent.adopt(scope, label: "subscription")
    }

    /// Returns local, safe ownership diagnostics. This is not a wire or
    /// ``NodeRuntime`` API.
    func effectSnapshot() async -> RuntimeEffectSnapshot {
        await scope.snapshot()
    }
}
