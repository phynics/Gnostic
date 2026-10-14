// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing
import GnosticCore
import GnosticProtocol
import PKContracts
import PositronicKit
@testable import GnosticPositronicBackend

@Suite("Positronic value bridges")
struct PositronicBridgeTests {
    @Test("the JSON value bridge round-trips every value case")
    func jsonValueBridgeRoundTripsEveryCase() {
        let values: [ManifestJSONValue] = [
            .string("value"),
            .number(0),
            .number(-1.5),
            .bool(true),
            .object(["nested": .array([.number(2), .null])]),
            .array([.string("a"), .bool(false)]),
            .null,
        ]
        for value in values {
            #expect(PositronicJSONValueBridge.manifestValue(PositronicJSONValueBridge.anyCodable(value)) == value)
        }
    }

    @Test("the JSON value bridge preserves 64-bit integers and floats")
    func jsonValueBridgePreservesWideNumbers() {
        #expect(PositronicJSONValueBridge.manifestValue(Int64(42)) == .number(42))
        #expect(PositronicJSONValueBridge.manifestValue(UInt64(42)) == .number(42))
        #expect(PositronicJSONValueBridge.manifestValue(Int(42)) == .number(42))
        #expect(PositronicJSONValueBridge.manifestValue(Float(1.5)) == .number(1.5))
        #expect(PositronicJSONValueBridge.manifestValue(AnyCodable.integer(42)) == .number(42))
        #expect(PositronicJSONValueBridge.manifestValue(AnyCodable.unsignedInteger(42)) == .number(42))
        #expect(PositronicJSONValueBridge.manifestValue(AnyCodable.number(1.5)) == .number(1.5))
    }

    @Test("the reference bridge maps every PositronicKit provider status")
    func referenceBridgeMapsProviderStatus() {
        let cases: [(WorkspaceReference.WorkspaceStatus, GnosticWorkspaceStatus, BackendWorkspaceStatus)] = [
            (.active, .active, .available),
            (.missing, .missing, .unavailable),
            (.unknown, .unknown, .unavailable),
        ]
        for (provider, expectedProviderStatus, expectedEffectiveStatus) in cases {
            let reference = WorkspaceReference(
                id: UUID(),
                uri: WorkspaceURI(parsing: "echo://provider-status")!,
                location: .runtime,
                status: provider
            )
            #expect(PositronicWorkspaceProjection.networkReference(from: reference).status == expectedProviderStatus)
            #expect(PositronicWorkspaceProjection.backendReference(from: reference).status == expectedEffectiveStatus)
        }
    }

    @Test("the reference bridge maps every Gnostic provider status and location")
    func referenceBridgeMapsGnosticStatusAndLocation() throws {
        for status in [GnosticWorkspaceStatus.active, .missing, .unknown] {
            for location in [GnosticWorkspaceLocation.runtime, .runtimeThread, .attached] {
                let gnostic = GnosticWorkspaceReference(
                    id: UUID(),
                    uri: "echo://gnostic-status",
                    location: location,
                    status: status
                )
                let reference = try PositronicWorkspaceProjection.reference(from: gnostic)
                #expect(reference.status.rawValue == status.rawValue)
                #expect(reference.location.rawValue == location.rawValue)
            }
        }
    }

    @Test("the reference bridge maps every backend status and location")
    func referenceBridgeMapsBackendStatusAndLocation() throws {
        let cases: [(BackendWorkspaceStatus, WorkspaceReference.WorkspaceStatus)] = [
            (.available, .active),
            (.unavailable, .missing),
            (.unsupported, .unknown),
        ]
        for (backend, expected) in cases {
            let reference = try PositronicWorkspaceProjection.reference(from: BackendWorkspaceReference(
                id: UUID(),
                uri: "echo://backend-status",
                status: backend
            ))
            #expect(reference.status == expected)
            #expect(reference.location == .runtime)
        }
    }

    @Test("a Workspace tool argument preserves a 64-bit integer and a float")
    @MainActor
    func workspaceToolArgumentPreservesWideNumbers() async throws {
        let service = RecordingWorkspaceService()
        let workspace = PositronicBackendWorkspace(
            reference: WorkspaceReference(
                id: UUID(),
                uri: WorkspaceURI(parsing: "echo://value-bridge")!,
                location: .runtime,
                status: .active
            ),
            service: service
        )

        _ = try await workspace.executeTool(id: "echo", parameters: [
            "count": AnyCodable.integer(42),
            "ratio": AnyCodable.number(1.5),
        ])

        let received = try #require(service.received)
        #expect(received["count"] == .number(42))
        #expect(received["ratio"] == .number(1.5))
    }
}

@MainActor
private final class RecordingWorkspaceService: AscendantBackendWorkspaceService {
    private(set) var received: [String: ManifestJSONValue]?

    func reference(id _: UUID) async -> BackendWorkspaceReference? { nil }

    func invoke(_ invocation: BackendWorkspaceInvocation) async throws -> BackendWorkspaceResult {
        received = invocation.arguments
        return .success("ok")
    }
}
