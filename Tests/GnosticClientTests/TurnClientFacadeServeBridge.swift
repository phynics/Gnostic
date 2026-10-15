// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
@testable import GnosticCore

/// Test-only serve-side scaffolding for the public turn client tests.
///
/// This file uses `@testable import` so the consumer-facing
/// `TurnClientFacadeTests.swift` compiles against the public `GnosticCore` API
/// only. The internal `AscendantTurnUpdateStore.events()` accessor is the only
/// testable symbol used here; the bridge stands in for a serve runtime's own
/// update publish loop.
@MainActor
enum TurnClientFacadeServeBridge {
    /// Forwards retained Turn update events to the public update channel.
    ///
    /// - Parameters:
    ///   - store: The serve-side update store.
    ///   - manager: The provider's transport.
    /// - Returns: The forwarding task, which the caller cancels at teardown.
    static func forwardUpdates(
        from store: AscendantTurnUpdateStore,
        to manager: CommunicationManager
    ) -> Task<Void, Never> {
        Task {
            let events = await store.events()
            for await event in events {
                if let channel = try? AscendantTurnProvider.updateEvent(event) {
                    manager.publishChannel(channel)
                }
            }
        }
    }
}
