// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

@testable import GnosticCLI

@Suite("ACP transport selection")
struct ACPTransportSelectionTests {
    @Test("Ascendant selection requires stable text-turn capability")
    @MainActor
    func selectionRequiresStableTextTurnCapability() throws {
        let timelineID = UUID(uuidString: "C41D0000-0000-4000-8000-000000000021")!
        let incapable = RemoteTurnClient.DiscoveredAscendant(
            id: UUID(uuidString: "C41D0000-0000-4000-8000-000000000022")!,
            name: "Experimental",
            timelineID: timelineID,
            providerID: "provider-a",
            capabilities: ["x-example.future-turn-mode"]
        )
        let capable = RemoteTurnClient.DiscoveredAscendant(
            id: UUID(uuidString: "C41D0000-0000-4000-8000-000000000023")!,
            name: "Text Ascendant",
            timelineID: timelineID,
            providerID: "provider-b",
            capabilities: ["x-example.future-turn-mode", GnosticCapability.textTurnInput]
        )

        let selected = try RemoteTurnClient.selectCandidate(from: [incapable, capable])
        #expect(selected.id == capable.id)
        #expect(selected.capabilities.contains("x-example.future-turn-mode"))

        do {
            _ = try RemoteTurnClient.selectCandidate(from: [incapable])
            Issue.record("an Ascendant without textTurnInput was selected")
        } catch let error as RemoteTurnClientError {
            #expect(error.gnosticCode == "missingCapability")
        }
    }
}
