// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// One single-flight compare-and-swap coordinator per Ascendant.
///
/// A flush captures immutable input, invokes the integrator outside the store
/// actor, validates the untrusted proposal, and commits with compare-and-swap.
/// A stale or catalog-changed CAS is retried exactly once against a fresh
/// capture; a second retryable failure surfaces. Reports appended during
/// integration are outside the capture and remain pending.
///
/// Concurrent flushes for one Ascendant share one task and observe one
/// outcome. Different Ascendants use different coordinators and proceed
/// independently.
public actor AtlasIntegrationCoordinator {
    private let store: any AtlasStore
    private let integrator: any AtlasIntegrator
    private let validator: AtlasHostValidator
    private let observer: (any AtlasAcceptedChangeObserver)?

    private var inFlight: Task<AtlasIntegrationOutcome, Error>?

    /// Creates a coordinator for one Ascendant store.
    public init(
        store: any AtlasStore,
        integrator: any AtlasIntegrator,
        observer: (any AtlasAcceptedChangeObserver)? = nil,
        validator: AtlasHostValidator = AtlasHostValidator()
    ) {
        self.store = store
        self.integrator = integrator
        self.observer = observer
        self.validator = validator
    }

    /// Whether a flush task is currently in flight.
    public var isFlushing: Bool { inFlight != nil }

    /// Runs one explicit integration flush, joining an existing one when
    /// present.
    ///
    /// - Throws: ``AtlasIntegrationError`` for a rejected proposal and the
    ///   underlying store error for an unresolvable commit. Waiting callers
    ///   share the first task's result or error.
    public func flush() async throws -> AtlasIntegrationOutcome {
        if let existing = inFlight {
            return try await existing.value
        }
        let task = Task { try await self.performFlush() }
        inFlight = task
        return try await task.value
    }

    private func performFlush() async throws -> AtlasIntegrationOutcome {
        defer { inFlight = nil }

        var attempt = 1
        while true {
            let capture = await store.capture()
            guard !capture.pendingReports.isEmpty else { return .noWork }

            let descriptor = integrator.descriptor
            let proposal = try await integrator.integrate(AtlasIntegrationRequest(
                capture: capture,
                maximumOperations: descriptor.maximumOperations,
                maximumProseBytes: descriptor.maximumProseBytes
            ))
            let validated = try validator.validate(
                descriptor: descriptor,
                capture: capture,
                proposal: proposal
            )

            do {
                let receipt = try await store.compareAndSwap(capture: capture, patch: validated.patch)
                let diagnostic = AtlasAcceptedChangeDiagnostic(
                    ascendantID: capture.ascendantID,
                    patchID: validated.patch.id,
                    captureID: capture.id,
                    baseVersion: receipt.acceptedPatch.baseVersion,
                    resultingVersion: receipt.acceptedPatch.resultingVersion,
                    isSemantic: validated.isSemantic,
                    operationCount: validated.patch.operations.count,
                    consumedReportCount: validated.consumedReportCount,
                    itemCount: receipt.state.items.count,
                    conflictCount: receipt.state.conflicts.count,
                    directiveCount: receipt.state.directives.count,
                    integratorIdentifier: descriptor.identifier,
                    integratorVersion: descriptor.version,
                    attempt: attempt,
                    wasIdempotent: receipt.wasIdempotent
                )
                await observer?.accept(diagnostic)
                return .committed(receipt: receipt, diagnostic: diagnostic)
            } catch let error as AtlasStoreError where error.retryable && attempt == 1 {
                attempt = 2
            }
        }
    }
}
