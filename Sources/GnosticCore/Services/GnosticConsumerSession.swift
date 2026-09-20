// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The broker endpoint and credentials a consumer session connects with.
///
/// Empty credential strings are normalized to `nil` at creation, so a caller
/// can pass `""` from configuration or an environment fallback without asking
/// the broker to authenticate with a blank value.
public struct GnosticBrokerSettings: Sendable, Equatable {
    /// The MQTT broker host.
    public let host: String

    /// The MQTT broker port.
    public let port: Int

    /// The Axoloty namespace shared with the serving Node.
    public let namespace: String

    /// The broker username, or `nil` for anonymous access.
    public let username: String?

    /// The broker password, or `nil` for anonymous access.
    public let password: String?

    /// Creates broker settings, clearing empty credential strings.
    ///
    /// - Parameters:
    ///   - host: The MQTT broker host.
    ///   - port: The MQTT broker port.
    ///   - namespace: The Axoloty namespace shared with the serving Node.
    ///   - username: The broker username, or `nil` for anonymous access.
    ///   - password: The broker password, or `nil` for anonymous access.
    public init(
        host: String,
        port: Int,
        namespace: String,
        username: String? = nil,
        password: String? = nil
    ) {
        self.host = host
        self.port = port
        self.namespace = namespace
        self.username = username.flatMap { $0.isEmpty ? nil : $0 }
        self.password = password.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Failures produced while connecting to and reading from a consumer session.
public enum GnosticConsumerSessionError: Error, Sendable, Equatable, LocalizedError {
    /// The broker did not come online within the connect timeout.
    case brokerUnreachable(String)

    /// The session could not establish its transport or subscription.
    case connectionFailed(String)

    /// A password was supplied without a username, which MQTT forbids on the wire.
    case invalidCredentials

    /// An operation required a running session.
    case notStarted

    /// The session was already stopped; a session is single-use.
    case alreadyStopped

    /// A stable, machine-readable reason label.
    public var reasonCode: String {
        switch self {
        case .brokerUnreachable: "brokerUnreachable"
        case .connectionFailed: "connectionFailed"
        case .invalidCredentials: "invalidCredentials"
        case .notStarted: "notStarted"
        case .alreadyStopped: "alreadyStopped"
        }
    }

    /// A stable, human-readable description of the failure.
    public var errorDescription: String? {
        switch self {
        case let .brokerUnreachable(detail): "Could not reach the MQTT broker: \(detail)"
        case let .connectionFailed(detail): "Connection failed: \(detail)"
        case .invalidCredentials: "A broker password requires a username."
        case .notStarted: "The consumer session is not started."
        case .alreadyStopped: "The consumer session was already stopped."
        }
    }
}

/// A public consumer facade over the connect, discover, and catalog seams.
///
/// The facade owns a ``GnosticSubscription`` and a ``NetworkCatalog``. It
/// connects to a broker, waits for the transport to come online within a
/// bounded window, ingests advertisements, issues active discovery requests,
/// and exposes the catalog for reading. It hides the generic Axoloty host
/// objects so an external consumer does not need to build them.
///
/// ## Timeouts
///
/// `connectTimeout` bounds the wait for the transport to report online. When
/// it elapses, ``start()`` tears the session down and throws
/// ``GnosticConsumerSessionError/brokerUnreachable(_:)``. `discoverTimeout`
/// bounds how long ``discover(timeout:)`` collects resolve responses; the
/// broker request stream stays open for the request lifetime, so discovery
/// returns at the deadline rather than waiting for a stream end. A per-call
/// timeout overrides the configured default.
///
/// ## Deadvertisement
///
/// A per-object deadvertisement removes only that provider's record. A
/// lifecycle identity deadvertisement removes every record owned by the
/// provider. Both changes surface through ``catalogUpdates()`` as
/// ``NetworkCatalogChange/deadvertised(objectID:providerID:)`` and
/// ``NetworkCatalogChange/providerEvicted(_:)``, and are reflected by
/// ``networkObjects(includeIncompatible:)`` and ``object(id:providerID:)``.
///
/// ## Lifecycle
///
/// A session is single-use. Create one, ``start()`` it once, then ``stop()``
/// it. Calling ``start()`` again after a failed start or after ``stop()``
/// throws ``GnosticConsumerSessionError/alreadyStopped``.
@MainActor
public final class GnosticConsumerSession {
    /// The broker endpoint and credentials this session connects with.
    public let broker: GnosticBrokerSettings

    /// The Axoloty identity name this session publishes.
    public let identityName: String

    /// The bounded window in which the transport must report online.
    public let connectTimeout: Duration

    /// The default window used by ``discover(timeout:)`` to collect responses.
    public let discoverTimeout: Duration

    private enum State: Equatable {
        case ready
        case running
        case stopped
    }

    private let manager: CommunicationManager
    private let catalog: NetworkCatalog
    private let subscription: GnosticSubscription
    private var state = State.ready

    /// Creates a session bound to a broker namespace.
    ///
    /// The session is not connected until ``start()`` is called.
    ///
    /// - Parameters:
    ///   - broker: The broker endpoint and credentials.
    ///   - identityName: The Axoloty identity this session publishes.
    ///   - connectTimeout: The bounded online wait used by ``start()``.
    ///   - discoverTimeout: The default discovery collection window.
    /// - Throws: An error when the underlying Axoloty host cannot be built.
    public init(
        broker: GnosticBrokerSettings,
        identityName: String = "gnostic-consumer",
        connectTimeout: Duration = .seconds(5),
        discoverTimeout: Duration = .seconds(5)
    ) throws {
        self.broker = broker
        self.identityName = identityName
        self.connectTimeout = connectTimeout
        self.discoverTimeout = discoverTimeout
        catalog = NetworkCatalog()
        manager = try CommunicationManager(
            identity: Identity(name: identityName),
            communicationOptions: CommunicationOptions(
                namespace: broker.namespace,
                shouldEnableCrossNamespacing: false,
                mqttClientOptions: MQTTClientOptions(
                    host: broker.host,
                    port: UInt16(clamping: broker.port),
                    shouldTryMDNSDiscovery: false,
                    username: broker.username,
                    password: broker.password,
                    autoReconnect: false
                ),
                shouldAutoStart: false
            ),
            commonOptions: nil
        )
        subscription = GnosticSubscription(catalog: catalog, communicationManager: manager)
    }

    /// Starts the transport, waits for online, then subscribes to Gnostic
    /// advertisements.
    ///
    /// - Throws: ``GnosticConsumerSessionError`` when credentials are invalid,
    ///   the broker is unreachable within `connectTimeout`, or the
    ///   subscription cannot start. The session is torn down on any failure.
    public func start() async throws {
        switch state {
        case .running:
            return
        case .stopped:
            throw GnosticConsumerSessionError.alreadyStopped
        case .ready:
            break
        }

        guard !(broker.password != nil && broker.username == nil) else {
            state = .stopped
            await teardown()
            throw GnosticConsumerSessionError.invalidCredentials
        }

        do {
            let stateStream = await manager.observeCommunicationStateStream()
            try manager.start()
            guard await firstOnline(in: stateStream, timeout: connectTimeout) else {
                throw GnosticConsumerSessionError.brokerUnreachable("did not come online within \(connectTimeout)")
            }
            try await subscription.start()
            state = .running
        } catch let error as GnosticConsumerSessionError {
            state = .stopped
            await teardown()
            throw error
        } catch {
            state = .stopped
            await teardown()
            throw GnosticConsumerSessionError.connectionFailed(String(describing: error))
        }
    }

    /// Publishes one active discover request and ingests its resolve responses.
    ///
    /// - Parameter timeout: The collection window, or `nil` to use
    ///   ``discoverTimeout``.
    /// - Throws: ``GnosticConsumerSessionError/notStarted`` when the session is
    ///   not running.
    public func discover(timeout: Duration? = nil) async throws {
        guard state == .running else { throw GnosticConsumerSessionError.notStarted }
        await subscription.discover(using: manager, timeout: timeout ?? discoverTimeout)
    }

    /// Returns every currently advertised object.
    ///
    /// - Parameter includeIncompatible: Whether objects with an incompatible
    ///   protocol major are included. Defaults to `false`.
    /// - Returns: The provider-scoped catalog entries, sorted deterministically.
    public func networkObjects(includeIncompatible: Bool = false) async -> [NetworkCatalogEntry] {
        await catalog.networkObjects(includeIncompatible: includeIncompatible)
    }

    /// Returns one provider-scoped object record.
    ///
    /// - Parameters:
    ///   - id: The advertised object identifier.
    ///   - providerID: The provider identity that advertised the object.
    /// - Returns: The retained entry, or `nil` when it was never advertised or
    ///   was deadvertised.
    public func object(id: UUID, providerID: String) async -> NetworkCatalogEntry? {
        await catalog.object(id: id, providerID: providerID)
    }

    /// Returns one workspace descriptor with query-only tools merged in.
    ///
    /// - Parameters:
    ///   - id: The advertised workspace identifier.
    ///   - providerID: The provider identity that advertised the workspace.
    /// - Returns: The workspace descriptor, or `nil` when the catalog has no
    ///   well-formed workspace for that provider.
    public func workspaceDescriptor(id: UUID, providerID: String) async -> NetworkWorkspaceDescriptor? {
        await catalog.workspaceDescriptor(id: id, providerID: providerID)
    }

    /// Observes advertisements, deadvertisements, and provider evictions
    /// ingested by this session.
    ///
    /// Advertisement observation begins at ``start()`` and stops at ``stop()``.
    ///
    /// - Returns: A bounded, latest-biased stream of catalog changes.
    public func catalogUpdates() async -> AsyncStream<NetworkCatalogChange> {
        await catalog.changes()
    }

    /// Creates a public turn client over this session's connected transport.
    ///
    /// The session keeps ownership of the connection. The returned client
    /// shares the session's subscription and catalog, so it runs Turns and
    /// answers permission requests without a second connection, a hosted Node,
    /// or any advertisement.
    ///
    /// - Parameters:
    ///   - timeout: The bounded window for replay and provider discovery.
    ///   - promptTimeout: The bounded window for a Turn call. Defaults to
    ///     `timeout`.
    /// - Returns: A turn client bound to this session's transport.
    /// - Throws: ``GnosticConsumerSessionError/notStarted`` when the session is
    ///   not running.
    public func turnClient(
        timeout: Duration = .seconds(5),
        promptTimeout: Duration? = nil
    ) throws -> GnosticTurnClient {
        guard state == .running else { throw GnosticConsumerSessionError.notStarted }
        return GnosticTurnClient(
            manager: manager,
            catalog: catalog,
            subscription: subscription,
            timeout: timeout,
            promptTimeout: promptTimeout ?? timeout
        )
    }

    /// Stops subscriptions and the transport with ordered cleanup.
    ///
    /// Safe to call before ``start()`` and safe to call more than once. A
    /// stopped session cannot be restarted.
    public func stop() async {
        guard state != .stopped else { return }
        state = .stopped
        await teardown()
    }

    /// Waits for the first `.online` state within a bounded window.
    private func firstOnline(in stream: AsyncStream<CommunicationState>, timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await state in stream where state == .online {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let online = await group.next() ?? false
            group.cancelAll()
            return online
        }
    }

    /// Releases the subscription scope and the transport exactly once.
    ///
    /// Transport teardown stays synchronous, matching the established client
    /// path: an active discover request has no broker-side deadline, so an
    /// awaited runtime stop can block on it. The manager owns its own teardown
    /// task, so the session does not await it here.
    private func teardown() async {
        await subscription.stopAndWait()
        await subscription.disposeScope()
        manager.stop()
    }
}
