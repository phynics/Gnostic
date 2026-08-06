// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Axoloty
import Foundation
import GnosticCore

/// `gnostic inspect` — list and dump advertised Gnostic objects.
struct InspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Inspect advertised Gnostic objects on the broker.",
        subcommands: [List.self, Object.self]
    )

    /// Common broker connection options, overridable per invocation.
    struct ConnectionOptions: ParsableArguments {
        @Option(name: .long, help: "MQTT broker host (overrides config).")
        var host: String?

        @Option(name: .long, help: "MQTT broker port (overrides config).")
        var port: Int?

        @Option(name: .long, help: "MQTT namespace (overrides config).")
        var namespace: String?

        @Option(name: .long, help: "Discovery collection window in seconds.")
        var observeSeconds: Double = 1.0

        /// The plain connection values used by the session.
        func values() -> InspectConnectionValues {
            InspectConnectionValues(
                host: host,
                port: port,
                namespace: namespace,
                observeSeconds: observeSeconds
            )
        }
    }

    /// `gnostic inspect list [--type ...]` — one line per advertised object.
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List advertised Gnostic objects."
        )

        @OptionGroup var connection: ConnectionOptions

        @Option(name: .long, help: "Filter by object type: agent, timeline, or workspace.")
        var type: String?

        @MainActor
        func run() async throws {
            let entries = try await InspectSession(values: connection.values()).collect()
            let filtered = entries.filter { entry in
                guard let type else { return true }
                return entry.objectType == Self.canonicalType(for: type)
            }
            print(InspectRenderer.listText(filtered), terminator: "")
        }

        static func canonicalType(for alias: String) -> String {
            switch alias.lowercased() {
            case "agent": GnosticObjectType.agent
            case "timeline": GnosticObjectType.timeline
            case "workspace": GnosticObjectType.workspace
            default: alias
            }
        }
    }

    /// `gnostic inspect object <uuid>` — dump one object's catalogued shape.
    struct Object: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "object",
            abstract: "Dump a single object's catalogued representation."
        )

        @OptionGroup var connection: ConnectionOptions

        @Argument(help: "The object UUID to inspect.")
        var uuid: String

        @Flag(name: .long, help: "Emit compact single-line JSON.")
        var json = false

        @MainActor
        func run() async throws {
            guard let id = UUID(uuidString: uuid) else {
                throw InspectError.malformedUUID(uuid)
            }
            let entries = try await InspectSession(values: connection.values()).collect()
            let matching = entries.filter { $0.objectID == id }
            let resolution = InspectRenderer.resolution(for: matching)
            switch resolution {
            case .found(let entry):
                print(try InspectRenderer.objectJSON(entry, compact: json), terminator: json ? "\n" : "")
            case .unknown:
                FileHandle.standardError.write(Data("No advertised object matches '\(uuid)'.\n".utf8))
                throw ExitCode(2)
            case .ambiguous:
                let providers = matching.map(\.providerID).joined(separator: ", ")
                FileHandle.standardError.write(Data("Object '\(uuid)' is advertised by multiple providers: \(providers).\n".utf8))
                throw ExitCode(2)
            }
        }
    }
}

/// Structured errors for the inspect subcommands.
public enum InspectError: Error, Sendable, LocalizedError {
    case malformedUUID(String)
    case notFound(String)
    case ambiguous(String, providers: [String])
    case brokerUnreachable(String)
    case connectionFailed(String)

    /// A stable, human-readable description of the failure.
    public var errorDescription: String? {
        switch self {
        case let .malformedUUID(uuid): "Invalid UUID '\(uuid)'."
        case let .notFound(uuid): "No advertised object matches '\(uuid)'."
        case let .ambiguous(uuid, providers): "Object '\(uuid)' is advertised by multiple providers: \(providers.joined(separator: ", "))."
        case let .brokerUnreachable(detail): "Could not reach the MQTT broker: \(detail)"
        case let .connectionFailed(detail): "Connection failed: \(detail)"
        }
    }
}

/// Plain broker connection values decoupled from ArgumentParser wrappers.
public struct InspectConnectionValues: Sendable {
    public var host: String?
    public var port: Int?
    public var namespace: String?
    public var observeSeconds: Double

    public init(host: String? = nil, port: Int? = nil, namespace: String? = nil, observeSeconds: Double = 1.0) {
        self.host = host
        self.port = port
        self.namespace = namespace
        self.observeSeconds = observeSeconds
    }
}

/// Bounded broker observation: connect, subscribe to canonical Gnostic types,
/// collect a deterministic snapshot within a deadline, then disconnect.
@MainActor
final class InspectSession {
    private let values: InspectConnectionValues

    init(values: InspectConnectionValues) {
        self.values = values
    }

    func collect() async throws -> [NetworkCatalogEntry] {
        let store = CLIConfigurationStore()
        let stored = try store.load()

        let host = values.host ?? stored.mqttHost
        let port = values.port ?? stored.mqttPort
        let namespace = values.namespace ?? stored.mqttNamespace

        let manager = try CommunicationManager(
            identity: Identity(name: "gnostic-inspect"),
            communicationOptions: CommunicationOptions(
                namespace: namespace,
                shouldEnableCrossNamespacing: false,
                mqttClientOptions: MQTTClientOptions(
                    host: host,
                    port: UInt16(clamping: port),
                    shouldTryMDNSDiscovery: false,
                    autoReconnect: false
                ),
                shouldAutoStart: false
            ),
            commonOptions: nil
        )

        let catalog = NetworkCatalog()
        let subscription = GnosticSubscription(catalog: catalog, communicationManager: manager)

        do {
            try await start(manager)
            try await subscription.start()
            // Bound the discovery window deterministically.
            try await Task.sleep(for: .seconds(values.observeSeconds))
            let entries = await catalog.networkObjects()
            subscription.stop()
            manager.stop()
            return entries
        } catch let error as InspectError {
            subscription.stop()
            manager.stop()
            throw error
        } catch {
            subscription.stop()
            manager.stop()
            if error is CancellationError {
                throw InspectError.brokerUnreachable("timed out")
            }
            throw InspectError.connectionFailed(String(describing: error))
        }
    }

    /// Starts the manager and waits for the connection to come online within a
    /// bounded window, failing fast with a structured error when the broker is
    /// unreachable.
    private func start(_ manager: CommunicationManager) async throws {
        try manager.start()

        // Observe the connection lifecycle in a child task, racing it against a
        // deadline. Cancelling the observer after the deadline surfaces its
        // latest result deterministically without a task group (region-isolation
        // friendly).
        let observer = Task { @MainActor () async -> Bool in
            let stream = await manager.observeCommunicationStateStream()
            for await state in stream where state == .online {
                return true
            }
            return false
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(values.observeSeconds))
        }
        await deadline.value
        observer.cancel()
        let online = await observer.value
        await deadline.value

        guard online else {
            throw InspectError.brokerUnreachable("timed out connecting")
        }
    }
}