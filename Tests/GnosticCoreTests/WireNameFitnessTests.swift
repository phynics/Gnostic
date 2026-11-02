// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
@testable import GnosticCore
import GnosticProtocol
import Testing

/// Architecture fitness for the names a Node puts on the wire (ADR 0021, D13, D17).
///
/// The test reads the lists the Axoloty registration really uses
/// (`CommunicationManager.registeredCallOperations`, its channel identifiers,
/// and the catalog's object types), not a copy of them.
@Suite("Wire name fitness")
struct WireNameFitnessTests {
    private var registeredWireNames: [String] {
        CommunicationManager.registeredCallOperations
            + CommunicationManager.registeredChannelIdentifiers
            + GnosticObjectType.supported
    }

    @Test("no registered wire name says ascendant")
    func noWireNameSaysAscendant() {
        let registered = registeredWireNames.filter { $0.lowercased().contains("ascendant") }
        #expect(registered.isEmpty, "A wire name says ascendant (D13, #675): \(registered.sorted())")
    }

    @Test("the live Turn, permission, and diagnostics operations use their Turn and Runtime instance names")
    func turnAndRuntimeInstanceWireNames() {
        let registered = Set(registeredWireNames)
        for name in [
            "me.atkn.gnostic.turn",
            "me.atkn.gnostic.turn.cancel",
            "me.atkn.gnostic.turn.replay",
            "me.atkn.gnostic.turn.update",
            "me.atkn.gnostic.permission.respond",
            "me.atkn.gnostic.permission.response",
            "me.atkn.gnostic.diagnostics.runtimeInstance",
            "me.atkn.gnostic.RuntimeInstance",
        ] {
            #expect(registered.contains(name), "\(name) is not registered")
        }
    }

    @Test("the deleted timeline Turn stack registers no wire name")
    func noUnwiredTimelineTurnNamesAreRegistered() {
        for name in registeredWireNames {
            #expect(!name.hasPrefix("me.atkn.gnostic.timeline.turn"), "\(name) belongs to the deleted stack")
            #expect(!name.hasPrefix("me.atkn.gnostic.timeline.permission"), "\(name) belongs to the deleted stack")
        }
    }

    @Test("every registered operation and channel is unique")
    func registrationHasNoDuplicates() {
        let names = CommunicationManager.registeredCallOperations + CommunicationManager.registeredChannelIdentifiers
        #expect(Set(names).count == names.count)
    }

    @Test("the Runtime instance wire type and manifest keys carry no Ascendant name")
    func runtimeInstanceTypeAndManifestKeys() throws {
        #expect(GnosticObjectType.runtimeInstance == "me.atkn.gnostic.RuntimeInstance")
        #expect(!GnosticObjectType.runtimeInstance.contains("Ascendant"))

        let manifest = NodeManifest.makeDefault(broker: .init(host: "localhost", port: 1883, namespace: "test"))
        let data = try JSONEncoder().encode(manifest)
        let jsonObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(jsonObject["ascendants"] == nil, "Root manifest JSON must not contain key 'ascendants'")
        #expect(jsonObject["runtimeInstances"] != nil, "Root manifest JSON must contain key 'runtimeInstances'")

        if let timelines = jsonObject["timelines"] as? [[String: Any]], let firstTimeline = timelines.first {
            #expect(firstTimeline["operatingAscendantID"] == nil, "Timeline JSON must not contain key 'operatingAscendantID'")
            #expect(firstTimeline["runtimeInstanceID"] != nil, "Timeline JSON must contain key 'runtimeInstanceID'")
        } else {
            Issue.record("timelines array missing in encoded manifest")
        }
    }
}
