// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticClient
import GnosticCore

/// Bounded broker observation through the public consumer facade: connect,
/// discover within the observe window, snapshot every advertised object
/// (including incompatible ones), then disconnect.
@MainActor
final class InspectSession {
    private let values: InspectConnectionValues

    init(values: InspectConnectionValues) {
        self.values = values
    }

    func collect() async throws -> [NetworkCatalogEntry] {
        try await Self.withRunningSession(values: values) { session in
            try await session.discover()
            return await session.networkObjects(includeIncompatible: true)
        }
    }

    /// Runs one body against a started consumer session and always stops it.
    ///
    /// Session and cancellation failures map to ``InspectError``; every other
    /// failure, including ``GnosticDiagnosticsClientError`` and
    /// ``InspectError``, propagates unchanged so a caller can map it at its
    /// own seam.
    ///
    /// - Parameters:
    ///   - values: The resolved broker connection values.
    ///   - body: The work to run against the running session.
    /// - Returns: The body's value.
    /// - Throws: ``InspectError`` for connection failures, or the body's error.
    static func withRunningSession<T>(
        values: InspectConnectionValues,
        _ body: (GnosticConsumerSession) async throws -> T
    ) async throws -> T {
        let stored = try CLIConfigurationStore().load()
        let window = Duration.seconds(values.observeSeconds)
        let session = try GnosticConsumerSession(
            broker: GnosticBrokerSettings(
                host: values.host ?? stored.mqttHost,
                port: values.port ?? stored.mqttPort,
                namespace: values.namespace ?? stored.mqttNamespace,
                username: stored.mqttUsername,
                password: stored.mqttPassword
            ),
            identityName: "gnostic-inspect",
            connectTimeout: window,
            discoverTimeout: window
        )
        do {
            try await session.start()
            let result = try await body(session)
            await session.stop()
            return result
        } catch let error as GnosticConsumerSessionError {
            await session.stop()
            switch error {
            case .brokerUnreachable:
                throw InspectError.brokerUnreachable("timed out connecting")
            case let .connectionFailed(detail):
                throw InspectError.connectionFailed(detail)
            case .invalidCredentials, .notStarted, .alreadyStopped:
                throw InspectError.connectionFailed(error.errorDescription ?? error.reasonCode)
            }
        } catch is CancellationError {
            await session.stop()
            throw InspectError.brokerUnreachable("timed out")
        } catch let error as InspectError {
            await session.stop()
            throw error
        } catch let error as GnosticDiagnosticsClientError {
            await session.stop()
            throw error
        } catch {
            await session.stop()
            throw InspectError.connectionFailed(String(describing: error))
        }
    }
}
