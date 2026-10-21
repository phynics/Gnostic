// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticACPAscendant
import GnosticCore
import GnosticHost
import GnosticLegacyPositronicHost
import GnosticLettaBackend
import Testing
import GnosticPositronicBackend

@testable import GnosticRunner

/// Composition evidence for GNO-PLAT-012 (#446).
///
/// The runner composes through `GnosticHost`. This suite asserts the runner's
/// adapters come from ``BackendComposition``, that the composition carries
/// every backend kind `gnostic serve` has, and that the runner keeps no private
/// Ascendant registry.
@Suite("Runner composition")
struct RunnerCompositionTests {
    private static let runnerRuntimePath = "Sources/GnosticRunner/RunnerRuntime.swift"

    @Test("the runner composes through the shared GnosticHost composition")
    @MainActor
    func runnerCompositionMatchesHost() {
        #expect(
            RunnerRuntime.composition.registeredKinds == GnosticHost.BackendComposition.default.registeredKinds,
            "The runner must compose from BackendComposition.default, not a narrower registry."
        )
        #expect(
            RunnerRuntime.composition.registeredPositronicExtensions
                == GnosticHost.BackendComposition.default.registeredPositronicExtensions
        )
        #expect(
            RunnerRuntime.composition.registeredPositronicExtensions.isEmpty,
            "The clean host installs no provider-specific contribution."
        )
        #expect(
            RunnerRuntime.composition.registeredKinds.isSuperset(of: [
                LettaAscendantBackend.kind,
                ACPAscendantBackend.kind,
            ]),
            "The runner must host every process-independent backend kind `gnostic serve` has."
        )
        let modules = Set(RunnerRuntime.composition.moduleDescriptors.map(\.name))
        #expect(modules.contains("rlm"))
        #expect(modules.contains("atlas"))
    }

    @Test("RunnerRuntime keeps no private Ascendant registry")
    func runnerKeepsNoPrivateRegistry() throws {
        let source = try String(contentsOf: Self.runnerRuntimeURL, encoding: .utf8)
        #expect(source.contains("BackendComposition"))
        #expect(
            !source.contains("AscendantAdapterRegistry"),
            "RunnerRuntime must reach the Ascendant registry through GnosticHost's BackendComposition."
        )
        #expect(!source.contains("registerBackend("))
        #expect(!source.contains("registerPositronicBackend("))
    }

    private static var runnerRuntimeURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(runnerRuntimePath)
    }
}
