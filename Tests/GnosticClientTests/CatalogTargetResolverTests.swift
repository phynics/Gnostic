// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
@testable import GnosticClient
@testable import GnosticCore
import Testing

/// Broker-free checks of the one catalog target policy every consumer client
/// shares. The facade suites keep the end-to-end behavior; these tests pin the
/// capability, mismatch, and ambiguity cases once, and the per-client mapping
/// of each failure to its public error.
@Suite("Catalog target resolver")
@MainActor
struct CatalogTargetResolverTests {
    @Test("an absent target fails as unavailable before any capability is read")
    func absentTargetIsUnavailable() {
        let entries = [entry(GnosticObjectType.runtimeInstance, id: UUID(), provider: "node-a")]

        #expect(CatalogTargetResolver.target(.timeline, id: UUID(), expectedProviderID: nil, requiredCapability: nil, in: entries)
            == .failure(.unavailable))
        #expect(CatalogTargetResolver.target(.runtimeInstance, id: UUID(), expectedProviderID: nil, requiredCapability: GnosticCapability.diagnostics, in: entries)
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

        #expect(CatalogTargetResolver.target(.timeline, id: timelineID, expectedProviderID: nil, requiredCapability: nil, in: entries)
            == .failure(.ambiguous))
        #expect(CatalogTargetResolver.target(.runtimeInstance, id: runtimeID, expectedProviderID: nil, requiredCapability: nil, in: entries)
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

        #expect(CatalogTargetResolver.target(.timeline, id: timelineID, expectedProviderID: "node-b", requiredCapability: nil, in: entries)
            == .failure(.providerMismatch))
        #expect(CatalogTargetResolver.target(.runtimeInstance, id: runtimeID, expectedProviderID: "node-b", requiredCapability: GnosticCapability.timelineManagement, in: entries)
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

        #expect(CatalogTargetResolver.target(.timeline, id: timelineID, expectedProviderID: "node-a", requiredCapability: GnosticCapability.textTurnInput, in: entries)
            == .success(CatalogTarget(providerID: "Node-A", runtimeInstanceID: runtimeID)))
    }

    @Test("without a required capability a Timeline resolves even when it names no operating Runtime instance")
    func timelineWithoutCapabilityNeedsNoOperatingRuntimeInstance() {
        let timelineID = UUID()
        let entries = [entry(GnosticObjectType.timeline, id: timelineID, provider: "node-a")]

        #expect(CatalogTargetResolver.target(.timeline, id: timelineID, expectedProviderID: nil, requiredCapability: nil, in: entries)
            == .success(CatalogTarget(providerID: "node-a", runtimeInstanceID: nil)))
        #expect(CatalogTargetResolver.target(.timeline, id: timelineID, expectedProviderID: nil, requiredCapability: GnosticCapability.textTurnInput, in: entries)
            == .failure(.unavailable))
    }

    @Test("a capability is provided by the operating Runtime instance, not by another instance of the provider")
    func capabilityIsScopedToOperatingRuntimeInstance() {
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
        #expect(CatalogTargetResolver.target(.timeline, id: timelineID, expectedProviderID: nil, requiredCapability: GnosticCapability.textTurnInput, in: entries)
            == .failure(.missingCapability(GnosticCapability.textTurnInput)))

        let withOperating = entries + [entry(GnosticObjectType.runtimeInstance, id: operatingID, provider: "node-a")]
        #expect(CatalogTargetResolver.target(.timeline, id: timelineID, expectedProviderID: nil, requiredCapability: GnosticCapability.textTurnInput, in: withOperating)
            == .success(CatalogTarget(providerID: "node-a", runtimeInstanceID: operatingID)))
    }

    @Test("an advertised Runtime instance provides Turn input, Timeline management, and diagnostics, and nothing else")
    func runtimeInstanceProvidesOnlyTheNamedCapabilities() {
        let timelineID = UUID()
        let runtimeID = UUID()
        let entries = [
            entry(GnosticObjectType.timeline, id: timelineID, provider: "node-a", properties: [
                "runtimeInstanceID": .string(runtimeID.uuidString),
            ]),
            entry(GnosticObjectType.runtimeInstance, id: runtimeID, provider: "node-a"),
        ]

        for capability in [GnosticCapability.textTurnInput, GnosticCapability.timelineManagement, GnosticCapability.diagnostics] {
            #expect(CatalogTargetResolver.target(.timeline, id: timelineID, expectedProviderID: nil, requiredCapability: capability, in: entries)
                == .success(CatalogTarget(providerID: "node-a", runtimeInstanceID: runtimeID)))
            #expect(CatalogTargetResolver.target(.runtimeInstance, id: runtimeID, expectedProviderID: nil, requiredCapability: capability, in: entries)
                == .success(CatalogTarget(providerID: "node-a", runtimeInstanceID: runtimeID)))
        }
        #expect(CatalogTargetResolver.target(.timeline, id: timelineID, expectedProviderID: nil, requiredCapability: GnosticCapability.workspaceAttachment, in: entries)
            == .failure(.missingCapability(GnosticCapability.workspaceAttachment)))
        #expect(GnosticCapability.providedByRuntimeInstance
            == [GnosticCapability.textTurnInput, GnosticCapability.timelineManagement, GnosticCapability.diagnostics])
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
        let capability = GnosticCapability.textTurnInput

        #expect(GnosticTurnClient.error(for: .unavailable, timeline: id) == .timelineUnavailable(id))
        #expect(GnosticTurnClient.error(for: .ambiguous, timeline: id) == .timelineAmbiguous(id))
        #expect(GnosticTurnClient.error(for: .missingCapability(capability), timeline: id) == .missingCapability(capability))

        #expect(GnosticWorkspaceClient.error(for: .unavailable, timeline: id) == .timelineUnavailable(id))
        #expect(GnosticWorkspaceClient.error(for: .ambiguous, timeline: id) == .timelineAmbiguous(id))
        #expect(GnosticWorkspaceClient.error(for: .missingCapability(capability), timeline: id) == .missingCapability(capability))

        #expect(GnosticTimelineClient.error(for: .unavailable, runtimeInstance: id) == .runtimeInstanceUnavailable(id))
        #expect(GnosticTimelineClient.error(for: .ambiguous, runtimeInstance: id) == .runtimeInstanceAmbiguous(id))
        #expect(GnosticTimelineClient.error(for: .unavailable, timeline: id) == .timelineUnavailable(id))
        #expect(GnosticTimelineClient.error(for: .ambiguous, timeline: id) == .timelineAmbiguous(id))

        #expect(GnosticDiagnosticsClient.error(for: .unavailable, runtimeInstance: id) == .runtimeInstanceUnavailable(id))
        #expect(GnosticDiagnosticsClient.error(for: .ambiguous, runtimeInstance: id) == .runtimeInstanceAmbiguous(id))
        #expect(GnosticDiagnosticsClient.error(for: .unavailable, timeline: id) == .timelineUnavailable(id))
        #expect(GnosticDiagnosticsClient.error(for: .ambiguous, timeline: id) == .timelineAmbiguous(id))
        #expect(GnosticDiagnosticsClient.nodeError(for: .unavailable) == .nodeUnavailable)
        #expect(GnosticDiagnosticsClient.nodeError(for: .ambiguous) == .nodeAmbiguous)
        #expect(GnosticDiagnosticsClient.nodeError(for: .missingCapability(GnosticCapability.diagnostics))
            == .missingCapability(GnosticCapability.diagnostics))
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
