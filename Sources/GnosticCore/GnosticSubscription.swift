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
    private var tasks: [Task<Void, Never>] = []

    /// Creates a subscription owner using a scoped Axoloty observation operation.
    public init(
        catalog: NetworkCatalog,
        observe: @escaping @MainActor @Sendable (String) async throws -> AsyncStream<AdvertiseEventSnapshot>
    ) {
        self.catalog = catalog
        self.observe = observe
    }

    /// Creates a subscription owner backed by an Axoloty communication manager.
    public convenience init(catalog: NetworkCatalog, communicationManager: CommunicationManager) {
        self.init(catalog: catalog) { objectType in
            try await communicationManager.observeAdvertiseStream(withObjectType: objectType)
        }
    }

    deinit { tasks.forEach { $0.cancel() } }

    /// Starts one scoped subscription for each canonical Gnostic object type.
    public func start() async throws {
        guard tasks.isEmpty else { return }
        for objectType in Self.objectTypes {
            let stream = try await observe(objectType)
            tasks.append(Task { [catalog] in
                for await event in stream { await catalog.ingest(event) }
            })
        }
    }

    /// Cancels all active subscriptions and releases their Axoloty stream lifetimes.
    public func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }
}
