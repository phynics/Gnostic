// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

public enum BridgeServerError: Error, LocalizedError, Sendable {
    case brokerLost

    public var errorDescription: String? {
        "The MQTT broker connection was lost."
    }
}

/// Runs one bridge session on stdin/stdout. Logs and broker failures stay out
/// of stdout so the stream remains valid JSON-RPC.
@MainActor
public struct BridgeServer: Sendable {
    private let session: BridgeSession
    private let client: GnosticRemoteClient

    public init(client: GnosticRemoteClient, output: @escaping BridgeSession.Output = { data in
        FileHandle.standardOutput.write(data)
    }) {
        self.client = client
        session = BridgeSession(handler: { [dispatcher = BridgeDispatcher(client: client)] request in
            try await dispatcher.handle(request)
        }, output: output)
    }

    /// Reads LF-delimited messages until stdin closes or the broker is lost.
    public func run() async throws {
        while !client.hasLostConnection {
            // JSON-RPC frames are intentionally small and may arrive one at a
            // time; consume whatever is currently available from the pipe.
            let data = await Task.detached {
                FileHandle.standardInput.availableData
            }.value
            if data.isEmpty { break }
            await session.receive(data)
            if await session.currentState() == .stopped { break }
        }
        await session.finish()
        if client.hasLostConnection {
            throw BridgeServerError.brokerLost
        }
    }
}
