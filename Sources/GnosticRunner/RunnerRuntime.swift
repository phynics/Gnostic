// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticHost

/// The runner's composition root.
///
/// `gnostic-runner` hosts the same backend kinds as `gnostic serve` because it
/// builds its adapters from ``BackendComposition``. The runner keeps no private
/// registry: a capability registered once in `GnosticHost` reaches both
/// executables, and a manifest that selects a non-Positronic backend is
/// accepted without a runner-specific change.
///
/// This type is the only startup path the runner has. It materializes a
/// ``NodeRuntime`` from a validated launch plan and delegates its lifecycle.
@MainActor
final class RunnerRuntime {
    /// The composition root shared with `gnostic serve`.
    static let composition = BackendComposition.default

    /// The hosted Node runtime.
    let runtime: NodeRuntime

    /// Composes and hosts the manifest in `configuration`.
    convenience init(configuration: RunnerConfiguration) async throws {
        try await self.init(plan: configuration.resolvedManifest().compileLaunchPlan())
    }

    /// Composes and hosts an already-compiled launch plan.
    ///
    /// - Parameters:
    ///   - plan: The validated Node launch plan to materialize.
    ///   - composition: The backend composition to install. Defaults to the
    ///     shared `GnosticHost` composition.
    init(plan: NodeLaunchPlan, composition: BackendComposition? = nil) async throws {
        let composition = composition ?? Self.composition
        runtime = try await NodeRuntime(plan: plan, adapters: composition.makeAdapters(for: plan.ascendants))
    }

    /// Starts the hosted Node and advertises its canonical objects.
    func start() async throws { try await runtime.start() }

    /// Stops the hosted Node and releases its resources.
    func shutdown() async { await runtime.shutdown() }
}
