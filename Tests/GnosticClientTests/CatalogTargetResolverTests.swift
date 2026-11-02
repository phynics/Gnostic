// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
@testable import GnosticClient
@testable import GnosticCore
import Testing

/// Broker-free checks of the one catalog target policy every consumer client
/// shares. The facade suites keep the end-to-end behavior; these tests pin the
/// Runtime instance, mismatch, and ambiguity cases once, and the per-client mapping
/// of each failure to its public error.
@Suite("Catalog target resolver")
@MainActor
struct CatalogTargetResolverTests {
    @Test("an absent target fails as unavailable before the operating Runtime instance is read")
    func absentTargetIsUnavailable() {
        let entries = [entry(GnosticObjectType.runtimeInstance, id: UUID(), provider: "node-a")]

        #expect(CatalogTargetResolver.target(.timeline, id: UUID(), expectedProviderID: nil, requiringRuntimeInstance: false, in: entries)
            == .failure(.unavailable))
        #expect(CatalogTargetResolver.target(.runtimeInstance, id: UUID(), expectedProviderID: nil, requiringRuntimeInstance: true, in: entries)
            == .failure(.unavailable))
    }

    @Test("a target advertised by two providers is ambiguous for every kind")
    func ambiguousTargetIsAmbiguous() {
        let timelineID = UUID()
        let runtimeID = UUID()
        let entries = [
            entry(GnosticObjectType.timeline, id: timelineID, provider: "node-a"),
            entry(GnosticObjectType.timeline, id: timelineID, provider: "node-b"),
            entry(GnosticObjectType.runtimeInstance, id: runtimeID, provider: "node-a"),
            entry(GnosticObjectType.runtimeInstance, id: runtimeID, provider: "node-b"),
        ]

        #expect(CatalogTargetResolver.target(.timeline, id: timelineID, expectedProviderID: nil, requiringRuntimeInstance: false, in: entries)
            == .failure(.ambiguous))
        #expect(CatalogTargetResolver.target(.runtimeInstance, id: runtimeID, expectedProviderID: nil, requiringRuntimeInstance: false, in: entries)
            == .failure(.ambiguous))
    }

    @Test("an expected provider that does not own the target is a provider mismatch for every kind")
    func expectedProviderMismatch() {
        let timelineID = UUID()
        let runtimeID = UUID()
        let entries = [
            entry(GnosticObjectType.timeline, id: timelineID, provider: "node-a"),
            entry(GnosticObjectType.runtimeInstance, id: runtimeID, provider: "node-a"),
        ]

        #expect(CatalogTargetResolver.target(.timeline, id: timelineID, expectedProviderID: "node-b", requiringRuntimeInstance: false, in: entries)
            == .failure(.providerMismatch))
        #expect(CatalogTargetResolver.target(.runtimeInstance, id: runtimeID, expectedProviderID: "node-b", requiringRuntimeInstance: true, in: entries)
            == .failure(.providerMismatch))
    }

    @Test("a successful resolution keeps the catalog's provider spelling and names the operating Runtime instance")
    func successCarriesProviderAndOperatingRuntimeInstance() {
        let timelineID = UUID()
        let runtimeID = UUID()
        let entries = [
            entry(GnosticObjectType.timeline, id: timelineID, provider: "Node-A", properties: [
                "runtimeInstanceID": .string(runtimeID.uuidString),
            ]),
            entry(GnosticObjectType.runtimeInstance, id: runtimeID, provider: "Node-A"),
        ]

        #expect(CatalogTargetResolver.target(.timeline, id: timelineID, expectedProviderID: "node-a", requiringRuntimeInstance: true, in: entries)
            == .success(CatalogTarget(providerID: "Node-A", runtimeInstanceID: runtimeID)))
    }

    @Test("without requiring the Runtime instance a Timeline resolves even when it names no operating Runtime instance")
    func timelineWithoutRequirementNeedsNoOperatingRuntimeInstance() {
        let timelineID = UUID()
        let entries = [entry(GnosticObjectType.timeline, id: timelineID, provider: "node-a")]

        #expect(CatalogTargetResolver.target(.timeline, id: timelineID, expectedProviderID: nil, requiringRuntimeInstance: false, in: entries)
            == .success(CatalogTarget(providerID: "node-a", runtimeInstanceID: nil)))
        #expect(CatalogTargetResolver.target(.timeline, id: timelineID, expectedProviderID: nil, requiringRuntimeInstance: true, in: entries)
            == .failure(.unavailable))
    }

    @Test("the operating Runtime instance must be advertised, not just another instance of the provider")
    func requirementIsScopedToOperatingRuntimeInstance() {
        let timelineID = UUID()
        let operatingID = UUID()
        let otherID = UUID()
        let entries = [
            entry(GnosticObjectType.timeline, id: timelineID, provider: "node-a", properties: [
                "runtimeInstanceID": .string(operatingID.uuidString),
            ]),
            entry(GnosticObjectType.runtimeInstance, id: otherID, provider: "node-a"),
        ]

        // The provider advertises a Runtime instance, but not the one that operates the Timeline.
        #expect(CatalogTargetResolver.target(.timeline, id: timelineID, expectedProviderID: nil, requiringRuntimeInstance: true, in: entries)
            == .failure(.runtimeInstanceUnavailable(operatingID)))

        let withOperating = entries + [entry(GnosticObjectType.runtimeInstance, id: operatingID, provider: "node-a")]
        #expect(CatalogTargetResolver.target(.timeline, id: timelineID, expectedProviderID: nil, requiringRuntimeInstance: true, in: withOperating)
            == .success(CatalogTarget(providerID: "node-a", runtimeInstanceID: operatingID)))
    }

    @Test("an advertised operating Runtime instance satisfies the requirement for a Timeline and for itself")
    func advertisedRuntimeInstanceSatisfiesTheRequirement() {
        let timelineID = UUID()
        let runtimeID = UUID()
        let entries = [
            entry(GnosticObjectType.timeline, id: timelineID, provider: "node-a", properties: [
                "runtimeInstanceID": .string(runtimeID.uuidString),
            ]),
            entry(GnosticObjectType.runtimeInstance, id: runtimeID, provider: "node-a"),
        ]

        #expect(CatalogTargetResolver.target(.timeline, id: timelineID, expectedProviderID: nil, requiringRuntimeInstance: true, in: entries)
            == .success(CatalogTarget(providerID: "node-a", runtimeInstanceID: runtimeID)))
        #expect(CatalogTargetResolver.target(.runtimeInstance, id: runtimeID, expectedProviderID: nil, requiringRuntimeInstance: true, in: entries)
            == .success(CatalogTarget(providerID: "node-a", runtimeInstanceID: runtimeID)))
    }

    @Test("the public mismatch error has one meaning in every client")
    func mismatchMapsToProviderMismatchEverywhere() {
        let id = UUID()

        #expect(GnosticTurnClient.error(for: .providerMismatch, timeline: id) == .providerMismatch)
        #expect(GnosticWorkspaceClient.error(for: .providerMismatch, timeline: id) == .providerMismatch)
        #expect(GnosticTimelineClient.error(for: .providerMismatch, timeline: id) == .providerMismatch)
        #expect(GnosticTimelineClient.error(for: .providerMismatch, runtimeInstance: id) == .providerMismatch)
        #expect(GnosticDiagnosticsClient.error(for: .providerMismatch, timeline: id) == .providerMismatch)
        #expect(GnosticDiagnosticsClient.error(for: .providerMismatch, runtimeInstance: id) == .providerMismatch)
    }

    @Test("each client maps the shared failure set to its own public errors")
    func failureMappingPerClient() {
        let id = UUID()
        let runtimeID = UUID()

        #expect(GnosticTurnClient.error(for: .unavailable, timeline: id) == .timelineUnavailable(id))
        #expect(GnosticTurnClient.error(for: .ambiguous, timeline: id) == .timelineAmbiguous(id))
        #expect(GnosticTurnClient.error(for: .runtimeInstanceUnavailable(runtimeID), timeline: id) == .runtimeInstanceUnavailable(runtimeID))

        #expect(GnosticWorkspaceClient.error(for: .unavailable, timeline: id) == .timelineUnavailable(id))
        #expect(GnosticWorkspaceClient.error(for: .ambiguous, timeline: id) == .timelineAmbiguous(id))

        #expect(GnosticTimelineClient.error(for: .unavailable, runtimeInstance: id) == .runtimeInstanceUnavailable(id))
        #expect(GnosticTimelineClient.error(for: .ambiguous, runtimeInstance: id) == .runtimeInstanceAmbiguous(id))
        #expect(GnosticTimelineClient.error(for: .unavailable, timeline: id) == .timelineUnavailable(id))
        #expect(GnosticTimelineClient.error(for: .ambiguous, timeline: id) == .timelineAmbiguous(id))
        #expect(GnosticTimelineClient.error(for: .runtimeInstanceUnavailable(runtimeID), timeline: id) == .runtimeInstanceUnavailable(runtimeID))

        #expect(GnosticDiagnosticsClient.error(for: .unavailable, runtimeInstance: id) == .runtimeInstanceUnavailable(id))
        #expect(GnosticDiagnosticsClient.error(for: .ambiguous, runtimeInstance: id) == .runtimeInstanceAmbiguous(id))
        #expect(GnosticDiagnosticsClient.error(for: .unavailable, timeline: id) == .timelineUnavailable(id))
        #expect(GnosticDiagnosticsClient.error(for: .ambiguous, timeline: id) == .timelineAmbiguous(id))
        #expect(GnosticDiagnosticsClient.error(for: .runtimeInstanceUnavailable(runtimeID), timeline: id) == .runtimeInstanceUnavailable(runtimeID))
        #expect(GnosticDiagnosticsClient.nodeError(for: .unavailable) == .nodeUnavailable)
        #expect(GnosticDiagnosticsClient.nodeError(for: .ambiguous) == .nodeAmbiguous)
    }

    private func entry(
        _ objectType: String,
        id: UUID,
        provider: String,
        properties: [String: NetworkDynamicValue] = [:]
    ) -> NetworkCatalogEntry {
        NetworkCatalogEntry(
            objectID: id,
            objectType: objectType,
            providerID: provider,
            name: "entry",
            knownProperties: properties,
            dynamicProperties: [:],
            workspace: nil
        )
    }
}
