// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

/// Characterization for the compatibility layer's encoded spellings. These
/// values are on the wire, so renaming Swift declarations must not move them.
@Suite("Compatibility wire spelling")
struct CompatibilityWireSpellingTests {
    @Test("CoreType keeps its encoded spelling regardless of Swift case naming")
    func coreTypeRawValuesAreStable() throws {
        #expect(CoreType(rawValue: "CoatyObject") != nil)
        #expect(CoreType(rawValue: "Identity") != nil)
        #expect(CoreType(rawValue: "coatyObject") == nil)

        let encoded = try JSONEncoder().encode(CoreType(rawValue: "CoatyObject"))
        #expect(String(decoding: encoded, as: UTF8.self) == "\"CoatyObject\"")
    }

    @Test("a CoatyObject snapshot encodes coreType with its wire spelling")
    func snapshotEncodesWireSpelling() throws {
        let snapshot = CoatyObjectSnapshot(
            objectId: "a21d0000-0000-4000-8000-000000000009",
            coreType: try #require(CoreType(rawValue: "CoatyObject")),
            objectType: "me.atkn.gnostic.Workspace",
            name: "Wire"
        )

        let data = try JSONEncoder().encode(snapshot)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["coreType"] as? String == "CoatyObject")
    }
}
