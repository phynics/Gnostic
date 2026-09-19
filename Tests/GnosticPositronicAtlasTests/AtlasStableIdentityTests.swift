// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticPositronicAtlas

@Suite("Atlas stable host identity")
struct AtlasStableIdentityTests {
    @Test("the identity digest matches the SHA-256 test vectors")
    func digestMatchesVectors() {
        #expect(hex(AtlasSHA256.digest("")) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(hex(AtlasSHA256.digest("abc")) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(
            hex(AtlasSHA256.digest("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
    }

    @Test("host identity is deterministic, domain-separated, and Ascendant-scoped")
    func identityIsDeterministicAndScoped() {
        let firstAscendant = UUID(uuidString: "A1170000-0000-4000-8000-000000000201")!
        let secondAscendant = UUID(uuidString: "A1170000-0000-4000-8000-000000000202")!
        let shardID = AscendantShardID(rawValue: UUID(uuidString: "A1170000-0000-4000-8000-000000000210")!)

        #expect(
            AtlasHostIdentity.itemID(ascendantID: firstAscendant, key: "response-style")
                == AtlasHostIdentity.itemID(ascendantID: firstAscendant, key: "response-style")
        )
        #expect(
            AtlasHostIdentity.itemID(ascendantID: firstAscendant, key: "response-style")
                != AtlasHostIdentity.itemID(ascendantID: firstAscendant, key: "other")
        )
        #expect(
            AtlasHostIdentity.itemID(ascendantID: firstAscendant, key: "response-style")
                != AtlasHostIdentity.itemID(ascendantID: secondAscendant, key: "response-style")
        )
        #expect(
            AtlasHostIdentity.itemID(ascendantID: firstAscendant, key: "k").rawValue
                != AtlasHostIdentity.directiveID(ascendantID: firstAscendant, shardID: nil, key: "k").rawValue
        )
        #expect(
            AtlasHostIdentity.conflictID(ascendantID: firstAscendant, shardID: shardID, itemIDs: [])
                == AtlasHostIdentity.conflictID(ascendantID: firstAscendant, shardID: shardID, itemIDs: [])
        )
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
