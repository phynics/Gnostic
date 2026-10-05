// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

@testable import GnosticRunner

/// Characterization evidence for GNO-PLAT-010 (#444).
///
/// `gnostic-runner` has no `NodeRuntimeAdapters` seam today. `RunnerRuntime`
/// builds one Axoloty `Components` value and never installs an Ascendant
/// backend, a Positronic extension, a Workspace adapter, or a terminal Turn
/// observer. `Container.resolve` ignores the `Components` value, so there is no
/// runtime seam to assert against; this suite records the composition from the
/// source and from the Core defaults the runner is described as using.
///
/// Recorded at `c592030`:
///
/// | Dimension | `gnostic-runner` installs |
/// | --- | --- |
/// | Backend kinds | none |
/// | Positronic extensions | none |
/// | Workspace adapters | none |
/// | Terminal Turn observers | none |
/// | Coaty object types | `GnosticAscendantObject`, `GnosticTimelineObject`, `GnosticWorkspaceObject` |
/// | Controllers | `ObjectLifecycleController` |
///
/// GNO-PLAT-012 (#446) must replace this record when the runner composes
/// through `GnosticHost`.
@Suite("Runner composition characterization")
struct RunnerCompositionCharacterizationTests {
    private static let runnerRuntimePath = "Sources/GnosticRunner/RunnerRuntime.swift"

    /// The runner target does not link a backend target, so the Core defaults
    /// are the only registered kinds it can reach.
    @Test("Core defaults expose Positronic, the echo Workspace, and no observer")
    func coreDefaultsShape() {
        let adapters = NodeRuntimeAdapters.default
        #expect(adapters.ascendants.registeredKinds == [AscendantAdapterRegistry.positronicKind])
        #expect(adapters.workspaces.registeredKinds == ["echo"])
        #expect(adapters.terminalTurnObservers.isEmpty)
    }

    @Test("RunnerRuntime installs no Ascendant backend, extension, Workspace adapter, or observer")
    func installsNoComposition() throws {
        let source = try String(contentsOf: Self.runnerRuntimeURL, encoding: .utf8)
        for symbol in [
            "AscendantAdapterRegistry",
            "BackendComposition",
            "WorkspaceAdapterRegistry",
            "PositronicExtension",
            "terminalTurnObservers",
            "registerBackend(",
            "registerPositronicBackend(",
        ] {
            #expect(
                !source.contains(symbol),
                "RunnerRuntime must not install \(symbol); GNO-PLAT-012 changes this deliberately."
            )
        }
    }

    @Test("RunnerRuntime registers the three Gnostic object types and the lifecycle controller")
    func registersGnosticObjects() throws {
        let source = try String(contentsOf: Self.runnerRuntimeURL, encoding: .utf8)
        #expect(source.contains("GnosticAscendantObject.self"))
        #expect(source.contains("GnosticTimelineObject.self"))
        #expect(source.contains("GnosticWorkspaceObject.self"))
        #expect(source.contains("ObjectLifecycleController.self"))
    }

    private static var runnerRuntimeURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(runnerRuntimePath)
    }
}
