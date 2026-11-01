// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
@testable import GnosticCore
import GnosticProtocol
import Testing

/// Architecture fitness for the names a Node puts on the wire (ADR 0021, D17).
///
/// The test reads the lists the Axoloty registration really uses
/// (`CommunicationManager.registeredCallOperations`, its channel identifiers,
/// and the catalog's object types), not a copy of them.
@Suite("Wire name fitness")
struct WireNameFitnessTests {
    /// The live wire names that still say "ascendant". #675 renames each one to
    /// its `Turn*` or Runtime-instance name and removes it from this list, so the
    /// list only shrinks. A new name containing "ascendant" fails the test, and
    /// so does an entry that production no longer registers.
    private static let ascendantWireNameAllowList: Set<String> = [
        "me.atkn.gnostic.ascendant.turn",
        "me.atkn.gnostic.ascendant.turn.cancel",
        "me.atkn.gnostic.ascendant.turn.replay",
        "me.atkn.gnostic.ascendant.turn.update",
        "me.atkn.gnostic.ascendant.permission.respond",
        "me.atkn.gnostic.ascendant.permission.response",
        "me.atkn.gnostic.diagnostics.ascendant",
        "me.atkn.gnostic.Ascendant",
    ]

    private var registeredWireNames: [String] {
        CommunicationManager.registeredCallOperations
            + CommunicationManager.registeredChannelIdentifiers
            + GnosticObjectType.supported
    }

    @Test("the wire names that still say ascendant are exactly the allow-list that #675 shrinks")
    func ascendantWireNamesMatchTheAllowList() {
        let registered = Set(registeredWireNames.filter { $0.lowercased().contains("ascendant") })
        #expect(
            registered.subtracting(Self.ascendantWireNameAllowList).isEmpty,
            "A new wire name says ascendant: \(registered.subtracting(Self.ascendantWireNameAllowList).sorted())"
        )
        #expect(
            Self.ascendantWireNameAllowList.subtracting(registered).isEmpty,
            "Remove from the allow-list, production no longer registers: \(Self.ascendantWireNameAllowList.subtracting(registered).sorted())"
        )
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
