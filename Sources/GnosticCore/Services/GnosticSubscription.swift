// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty

/// Owns bounded Axoloty advertisement subscriptions for Gnostic object types.
@MainActor
public final class GnosticSubscription {
    /// The exact object types observed by this subscription.
    public static let objectTypes = [
        GnosticObjectType.agent,
        GnosticObjectType.timeline,
        GnosticObjectType.workspace,
    ]

    private let catalog: NetworkCatalog
    private let observe: @MainActor @Sendable (String) async throws -> AsyncStream<AdvertiseEventSnapshot>
    private let observeDeadvertise: @MainActor @Sendable () async -> AsyncStream<DeadvertiseEventSnapshot>
    private var tasks: [Task<Void, Never>] = []

    /// Creates a subscription owner using a scoped Axoloty observation operation.
    public init(
        catalog: NetworkCatalog,
        observe: @escaping @MainActor @Sendable (String) async throws -> AsyncStream<AdvertiseEventSnapshot>,
        observeDeadvertise: @escaping @MainActor @Sendable () async -> AsyncStream<DeadvertiseEventSnapshot>
    ) {
        self.catalog = catalog
        self.observe = observe
        self.observeDeadvertise = observeDeadvertise
    }

    /// Creates a subscription owner backed by an Axoloty communication manager.
    public convenience init(catalog: NetworkCatalog, communicationManager: CommunicationManager) {
        self.init(catalog: catalog, observe: { objectType in
            try await communicationManager.observeAdvertiseStream(withObjectType: objectType)
        }, observeDeadvertise: {
            await communicationManager.observeDeadvertiseStream()
        })
    }

    deinit { tasks.forEach { $0.cancel() } }

    /// Starts one scoped subscription for each canonical Gnostic object type.
    public func start() async throws {
        guard tasks.isEmpty else { return }
        do {
            for objectType in Self.objectTypes {
                let stream = try await observe(objectType)
                tasks.append(Task { [catalog] in for await event in stream { await catalog.ingest(event) } })
            }
            let stream = await observeDeadvertise()
            tasks.append(Task { [catalog] in for await event in stream { await catalog.ingest(event) } })
        } catch {
            stop()
            throw error
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

    /// Cancels all active subscriptions and releases their Axoloty stream lifetimes.
    public func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }
}
