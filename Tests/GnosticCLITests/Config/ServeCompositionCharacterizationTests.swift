// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticACPAscendant
import GnosticCore
import GnosticHost
import GnosticLettaBackend
import Testing

@testable import GnosticCLI

/// Characterization evidence for GNO-PLAT-010 (#444).
///
/// This suite records what the `gnostic serve` / `gnostic config` composition
/// root installs today. It is an observation, not a contract: GNO-PLAT-011
/// (#445) may move `BackendComposition` into `GnosticHost`, and GNO-PLAT-012
/// (#446) brings the runner to the same composition. Both changes must keep
/// these assertions true or change this record deliberately.
///
/// Recorded at `c592030`:
///
/// | Dimension | `gnostic serve` installs |
/// | --- | --- |
/// | Backend kinds | `positronic`, `letta`, `acp-client` |
/// | Positronic extensions | `rlm` |
/// | Workspace adapters | `echo` (the Core default) |
/// | Terminal Turn observers | none |
@Suite("Serve composition characterization")
struct ServeCompositionCharacterizationTests {
    @Test("the serve path installs Positronic, Letta, and ACP backend kinds")
    func backendKinds() {
        #expect(BackendComposition.default.registeredKinds == [
            AscendantAdapterRegistry.positronicKind,
            LettaAscendantBackend.kind,
            ACPAscendantBackend.kind,
        ])
    }

    @Test("the serve path installs the rlm Positronic extension")
    func positronicExtensions() {
        #expect(BackendComposition.default.registeredPositronicExtensions == ["rlm"])
    }

    @Test("the serve path installs the echo Workspace adapter and no terminal observer")
    func workspaceAdaptersAndObservers() {
        let adapters = BackendComposition.default.makeAdapters()
        #expect(adapters.workspaces.registeredKinds == ["echo"])
        #expect(adapters.terminalTurnObservers.isEmpty)
    }

    @Test("the serve adapters expose the composition root's backend kinds")
    func adaptersMatchComposition() {
        let composition = BackendComposition.default
        let adapters = composition.makeAdapters()
        #expect(adapters.ascendants.registeredKinds == composition.registeredKinds)
    }

    @Test("an empty composition keeps the Core defaults")
    func emptyCompositionKeepsCoreDefaults() {
        let adapters = BackendComposition().makeAdapters()
        #expect(adapters.ascendants.registeredKinds == [AscendantAdapterRegistry.positronicKind])
        #expect(adapters.workspaces.registeredKinds == ["echo"])
        #expect(adapters.terminalTurnObservers.isEmpty)
    }
}
