// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticClient
import GnosticCore

/// Live, read-only diagnostics through the public consumer facade: connect,
/// resolve a capability-gated diagnostics client, read one payload-free
/// snapshot or the bounded raw wire-event stream, then disconnect.
///
/// Every method maps a ``GnosticDiagnosticsClientError`` to its ``InspectError``
/// form so the command layer reports one stable failure vocabulary.
@MainActor
final class InspectDiagnosticsSession {
    private let values: InspectConnectionValues

    init(values: InspectConnectionValues) {
        self.values = values
    }

    /// Reads payload-free live diagnostics for the whole Node.
    func node(providerID: String?) async throws -> NodeDiagnostics {
        try await run { session in
            try await session.diagnosticsClient(timeout: .seconds(self.values.observeSeconds))
                .node(providerID: providerID)
        }
    }

    /// Reads payload-free live diagnostics for one Ascendant.
    func ascendant(_ ascendantID: UUID, providerID: String?) async throws -> AscendantDiagnostics {
        try await run { session in
            try await session.diagnosticsClient(timeout: .seconds(self.values.observeSeconds))
                .ascendant(ascendantID, providerID: providerID)
        }
    }

    /// Reads payload-free live diagnostics for one Timeline.
    func timeline(_ timelineID: UUID, providerID: String?) async throws -> TimelineDiagnostics {
        try await run { session in
            try await session.diagnosticsClient(timeout: .seconds(self.values.observeSeconds))
                .timeline(timelineID, providerID: providerID)
        }
    }

    /// Collects raw wire-event envelopes without any payload.
    ///
    /// Without `follow`, the collection ends after the observe window or the
    /// requested event count, whichever comes first. With `follow`, the
    /// collection ends only at the requested count or at cancellation. The
    /// underlying facade stream is bounded and latest-biased, so the collection
    /// never blocks the runtime.
    ///
    /// - Parameters:
    ///   - follow: When true, keep observing past the observe window.
    ///   - count: Stop after this many events, or `nil` for no count bound.
    /// - Returns: The observed event envelopes, in arrival order.
    func events(follow: Bool, count: Int?) async throws -> [GnosticRawWireEvent] {
        try await InspectSession.withRunningSession(values: values) { session in
            await Self.collectEvents(
                from: session,
                follow: follow,
                count: count,
                observeSeconds: self.values.observeSeconds
            )
        }
    }

    private func run<T>(_ body: (GnosticConsumerSession) async throws -> T) async throws -> T {
        do {
            return try await InspectSession.withRunningSession(values: values, body)
        } catch let error as GnosticDiagnosticsClientError {
            throw InspectError(error)
        }
    }

    private static func collectEvents(
        from session: GnosticConsumerSession,
        follow: Bool,
        count: Int?,
        observeSeconds: Double
    ) async -> [GnosticRawWireEvent] {
        let base = await session.rawEvents()
        let (stream, continuation) = AsyncStream<GnosticRawWireEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        let forwarder = Task { @MainActor in
            for await event in base {
                continuation.yield(event)
            }
            continuation.finish()
        }
        let timer: Task<Void, Never>? = follow ? nil : Task { @MainActor in
            try? await Task.sleep(for: .seconds(observeSeconds))
            continuation.finish()
        }
        var collected: [GnosticRawWireEvent] = []
        if count == 0 {
            forwarder.cancel()
            timer?.cancel()
            return collected
        }
        for await event in stream {
            collected.append(event)
            if let count, collected.count >= count { break }
        }
        forwarder.cancel()
        timer?.cancel()
        return collected
    }
}
