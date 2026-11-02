// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticProtocol

/// Hosts the read-only diagnostics unary operations.
///
/// Three operations: `diagnostics.node`, `diagnostics.runtimeInstance`, and
/// `diagnostics.timeline`. Every executor returns payload-free runtime state;
/// the provider never mutates the Node.
public struct DiagnosticsProvider: Sendable {
    public static let nodeOperation = "me.atkn.gnostic.diagnostics.node"
    public static let runtimeInstanceOperation = "me.atkn.gnostic.diagnostics.runtimeInstance"
    public static let timelineOperation = "me.atkn.gnostic.diagnostics.timeline"

    public typealias NodeExecutor = @Sendable () async throws -> NodeDiagnostics
    public typealias RuntimeInstanceExecutor = @Sendable (UUID) async throws -> RuntimeInstanceDiagnostics
    public typealias TimelineExecutor = @Sendable (UUID) async throws -> TimelineDiagnostics

    private let node: NodeExecutor
    private let runtimeInstance: RuntimeInstanceExecutor
    private let timeline: TimelineExecutor

    public init(
        node: @escaping NodeExecutor,
        runtimeInstance: @escaping RuntimeInstanceExecutor,
        timeline: @escaping TimelineExecutor
    ) {
        self.node = node
        self.runtimeInstance = runtimeInstance
        self.timeline = timeline
    }

    public func handle(operation: String, parameters: String?) async throws -> CallHandlerResult {
        guard [Self.nodeOperation, Self.runtimeInstanceOperation, Self.timelineOperation].contains(operation) else {
            return .failure(code: 404, reasonCode: "unknownDiagnosticsOperation", message: "Unknown diagnostics operation")
        }
        if let failure = GnosticCallHandling.protocolFailure(
            parameters,
            invalidReasonCode: "invalidDiagnosticsPayload",
            invalidMessage: "Invalid diagnostics payload"
        ) {
            return failure
        }
        switch operation {
        case Self.nodeOperation:
            guard GnosticCallHandling.decode(DiagnosticsNodeRequest.self, from: parameters) != nil else {
                return .failure(code: 400, reasonCode: "invalidDiagnosticsPayload", message: "Invalid diagnostics.node payload")
            }
            return try await run {
                let snapshot = try await self.node()
                return try .encoded(snapshot, context: "diagnostics.node result")
            }
        case Self.runtimeInstanceOperation:
            guard let request = GnosticCallHandling.decode(DiagnosticsTargetRequest.self, from: parameters) else {
                return .failure(code: 400, reasonCode: "invalidDiagnosticsPayload", message: "Invalid diagnostics.runtimeInstance payload")
            }
            return try await run {
                let snapshot = try await self.runtimeInstance(request.id)
                return try .encoded(snapshot, context: "diagnostics.runtimeInstance result")
            }
        default:
            guard let request = GnosticCallHandling.decode(DiagnosticsTargetRequest.self, from: parameters) else {
                return .failure(code: 400, reasonCode: "invalidDiagnosticsPayload", message: "Invalid diagnostics.timeline payload")
            }
            return try await run {
                let snapshot = try await self.timeline(request.id)
                return try .encoded(snapshot, context: "diagnostics.timeline result")
            }
        }
    }

    private func run(_ body: () async throws -> CallHandlerResult) async throws -> CallHandlerResult {
        try await GnosticCallHandling.run(
            fallbackReasonCode: "diagnosticsOperationFailed",
            fallbackMessage: "The diagnostics operation failed.",
            body
        )
    }

    @MainActor
    public func register(on communication: CommunicationManager, context: CoatyObject? = nil) async throws -> [CallHandlerRegistration] {
        try await GnosticCallHandling.register(
            operations: [Self.nodeOperation, Self.runtimeInstanceOperation, Self.timelineOperation],
            on: communication,
            context: context
        ) { [self] operation, parameters in
            try await handle(operation: operation, parameters: parameters)
        }
    }
}
