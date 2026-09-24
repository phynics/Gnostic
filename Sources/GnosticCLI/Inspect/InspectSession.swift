// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
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
            try await session.discover()
            let entries = await session.networkObjects(includeIncompatible: true)
            await session.stop()
            return entries
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
        } catch {
            await session.stop()
            throw InspectError.connectionFailed(String(describing: error))
        }
    }
}
