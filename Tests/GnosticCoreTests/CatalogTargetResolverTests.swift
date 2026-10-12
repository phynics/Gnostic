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
        let entries = [entry(GnosticObjectType.ascendant, id: UUID(), provider: "node-a")]

        #expect(CatalogTargetResolver.target(.timeline, id: UUID(), expectedProviderID: nil, requiredCapability: nil, in: entries)
            == .failure(.unavailable))
        #expect(CatalogTargetResolver.target(.ascendant, id: UUID(), expectedProviderID: nil, requiredCapability: GnosticCapability.diagnostics, in: entries)
            == .failure(.unavailable))
    }

    @Test("a target advertised by two providers is ambiguous for every kind")
    func ambiguousTargetIsAmbiguous() {
        let timelineID = UUID()
        let ascendantID = UUID()
        let entries = [
            entry(GnosticObjectType.timeline, id: timelineID, provider: "node-a"),
            entry(GnosticObjectType.timeline, id: timelineID, provider: "node-b"),
            entry(GnosticObjectType.ascendant, id: ascendantID, provider: "node-a"),
            entry(GnosticObjectType.ascendant, id: ascendantID, provider: "node-b"),
        ]

        #expect(CatalogTargetResolver.target(.timeline, id: timelineID, expectedProviderID: nil, requiredCapability: nil, in: entries)
            == .failure(.ambiguous))
        #expect(CatalogTargetResolver.target(.ascendant, id: ascendantID, expectedProviderID: nil, requiredCapability: nil, in: entries)
            == .failure(.ambiguous))
    }

    @Test("an expected provider that does not own the target is a provider mismatch for every kind")
    func expectedProviderMismatch() {
        let timelineID = UUID()
        let ascendantID = UUID()
        let entries = [
            entry(GnosticObjectType.timeline, id: timelineID, provider: "node-a"),
            entry(GnosticObjectType.ascendant, id: ascendantID, provider: "node-a", properties: [
                "capabilities": .array([.string(GnosticCapability.timelineManagement)]),
            ]),
        ]

        #expect(CatalogTargetResolver.target(.timeline, id: timelineID, expectedProviderID: "node-b", requiredCapability: nil, in: entries)
            == .failure(.providerMismatch))
        #expect(CatalogTargetResolver.target(.ascendant, id: ascendantID, expectedProviderID: "node-b", requiredCapability: GnosticCapability.timelineManagement, in: entries)
            == .failure(.providerMismatch))
    }

    @Test("a successful resolution keeps the catalog's provider spelling and names the operating Ascendant")
    func successCarriesProviderAndOperatingAscendant() {
        let timelineID = UUID()
        let ascendantID = UUID()
        let entries = [
            entry(GnosticObjectType.timeline, id: timelineID, provider: "Node-A", properties: [
                "attachedAscendantID": .string(ascendantID.uuidString),
            ]),
            entry(GnosticObjectType.ascendant, id: ascendantID, provider: "Node-A", properties: [
                "capabilities": .array([.string(GnosticCapability.textTurnInput)]),
            ]),
        ]

        #expect(CatalogTargetResolver.target(.timeline, id: timelineID, expectedProviderID: "node-a", requiredCapability: GnosticCapability.textTurnInput, in: entries)
            == .success(CatalogTarget(providerID: "Node-A", ascendantID: ascendantID)))
    }

    @Test("without a required capability a Timeline resolves even when it names no operating Ascendant")
    func timelineWithoutCapabilityNeedsNoOperatingAscendant() {
        let timelineID = UUID()
        let entries = [entry(GnosticObjectType.timeline, id: timelineID, provider: "node-a")]

        #expect(CatalogTargetResolver.target(.timeline, id: timelineID, expectedProviderID: nil, requiredCapability: nil, in: entries)
            == .success(CatalogTarget(providerID: "node-a", ascendantID: nil)))
        #expect(CatalogTargetResolver.target(.timeline, id: timelineID, expectedProviderID: nil, requiredCapability: GnosticCapability.workspaceAttachment, in: entries)
            == .failure(.unavailable))
    }

    @Test("a required capability is read from the operating Ascendant, not another Ascendant of the provider")
    func capabilityIsScopedToOperatingAscendant() {
        let timelineID = UUID()
        let operatingID = UUID()
        let otherID = UUID()
        let entries = [
            entry(GnosticObjectType.timeline, id: timelineID, provider: "node-a", properties: [
                "attachedAscendantID": .string(operatingID.uuidString),
            ]),
            entry(GnosticObjectType.ascendant, id: operatingID, provider: "node-a", properties: [
                "capabilities": .array([.string(GnosticCapability.textTurnInput)]),
            ]),
            entry(GnosticObjectType.ascendant, id: otherID, provider: "node-a", properties: [
                "capabilities": .array([.string(GnosticCapability.workspaceAttachment)]),
            ]),
        ]

        #expect(CatalogTargetResolver.target(.timeline, id: timelineID, expectedProviderID: nil, requiredCapability: GnosticCapability.workspaceAttachment, in: entries)
            == .failure(.missingCapability(GnosticCapability.workspaceAttachment)))
        #expect(CatalogTargetResolver.target(.timeline, id: timelineID, expectedProviderID: nil, requiredCapability: GnosticCapability.textTurnInput, in: entries)
            == .success(CatalogTarget(providerID: "node-a", ascendantID: operatingID)))
    }

    @Test("an Ascendant target checks its own capability advertisement")
    func ascendantTargetChecksOwnCapability() {
        let ascendantID = UUID()
        let entries = [
            entry(GnosticObjectType.ascendant, id: ascendantID, provider: "node-a", properties: [
                "capabilities": .array([.string(GnosticCapability.diagnostics)]),
            ]),
        ]

        #expect(CatalogTargetResolver.target(.ascendant, id: ascendantID, expectedProviderID: nil, requiredCapability: GnosticCapability.diagnostics, in: entries)
            == .success(CatalogTarget(providerID: "node-a", ascendantID: ascendantID)))
        #expect(CatalogTargetResolver.target(.ascendant, id: ascendantID, expectedProviderID: nil, requiredCapability: GnosticCapability.timelineManagement, in: entries)
            == .failure(.missingCapability(GnosticCapability.timelineManagement)))
    }

    @Test("the public mismatch error has one meaning in every client")
    func mismatchMapsToProviderMismatchEverywhere() {
        let id = UUID()

        #expect(GnosticTurnClient.error(for: .providerMismatch, timeline: id) == .providerMismatch)
        #expect(GnosticWorkspaceClient.error(for: .providerMismatch, timeline: id) == .providerMismatch)
        #expect(GnosticTimelineClient.error(for: .providerMismatch, timeline: id) == .providerMismatch)
        #expect(GnosticTimelineClient.error(for: .providerMismatch, ascendant: id) == .providerMismatch)
        #expect(GnosticDiagnosticsClient.error(for: .providerMismatch, timeline: id) == .providerMismatch)
        #expect(GnosticDiagnosticsClient.error(for: .providerMismatch, ascendant: id) == .providerMismatch)
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

        #expect(GnosticTimelineClient.error(for: .unavailable, ascendant: id) == .ascendantUnavailable(id))
        #expect(GnosticTimelineClient.error(for: .ambiguous, ascendant: id) == .ascendantAmbiguous(id))
        #expect(GnosticTimelineClient.error(for: .unavailable, timeline: id) == .timelineUnavailable(id))
        #expect(GnosticTimelineClient.error(for: .ambiguous, timeline: id) == .timelineAmbiguous(id))

        #expect(GnosticDiagnosticsClient.error(for: .unavailable, ascendant: id) == .ascendantUnavailable(id))
        #expect(GnosticDiagnosticsClient.error(for: .ambiguous, ascendant: id) == .ascendantAmbiguous(id))
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
