// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticKit

/// Failures raised while resolving a Regime from a Node manifest.
public enum RegimeResolutionError: Error, Equatable, Sendable {
    /// The requested Ascendant is not declared in the manifest.
    case ascendantNotFound(UUID)
}

/// Resolves an Ascendant into its Regime (ADR 0013).
///
/// Every app that records or shows a Regime calls this one resolver, so
/// `config regime show`, `experiment run`, `rlm-scenario`, and replay name the
/// same value for the same Ascendant. It is pure: it reads the manifest and the
/// compiled composition, and it never builds a backend or a model client.
public enum RegimeResolver {
    /// Resolves the Regime one Ascendant runs under.
    ///
    /// Secret values are never part of the result.
    ///
    /// - Parameters:
    ///   - ascendantID: The Ascendant to resolve.
    ///   - manifest: The Node manifest that declares it.
    ///   - composition: The compiled composition source.
    /// - Returns: The Regime value shared by every run record and console.
    /// - Throws: ``RegimeResolutionError/ascendantNotFound(_:)`` when the
    ///   Ascendant is absent, or the composition's error when the module
    ///   selection is malformed.
    public static func resolve(
        ascendantID: UUID,
        manifest: NodeManifest,
        composition: BackendComposition = .default
    ) throws -> ExperimentRegime {
        guard let ascendant = manifest.ascendants.first(where: { $0.id == ascendantID }) else {
            throw RegimeResolutionError.ascendantNotFound(ascendantID)
        }
        let modules = try composition.selectedModuleNames(for: ascendant)
        let configuration = PositronicBackendConfiguration(backend: ascendant.backend)
        var modelTiers: [String: String] = [:]
        if let model = configuration.model { modelTiers["primary"] = model }
        if let utility = configuration.utilityModel { modelTiers["utility"] = utility }
        if let fast = configuration.fastModel { modelTiers["fast"] = fast }
        var versionByModule: [String: String] = [:]
        for module in modules {
            versionByModule[module] = composition.moduleDescriptor(named: module)?.registryID ?? module
        }
        return ExperimentRegime(
            backendKind: ascendant.backend.kind,
            modules: modules,
            moduleVersions: versionByModule,
            modelTiers: modelTiers,
            provider: configuration.provider ?? "",
            endpoint: configuration.endpoint ?? "",
            policies: [
                "approvalMode": manifest.node.approvalMode,
                "logLevel": manifest.node.logLevel,
            ]
        )
    }

    /// The Ascendant an omitted `--regime` resolves to.
    ///
    /// It is the Ascendant that operates the first Timeline that has one, and
    /// otherwise the first declared Ascendant. It returns `nil` for a manifest
    /// with no Ascendant.
    ///
    /// - Parameter manifest: The Node manifest.
    /// - Returns: The default operating Ascendant's UUID, if any.
    public static func defaultOperatingAscendantID(in manifest: NodeManifest) -> UUID? {
        let operated = manifest.timelines.first { timeline in
            guard let operatorID = timeline.operatingAscendantID else { return false }
            return manifest.ascendants.contains { $0.id == operatorID }
        }
        return operated?.operatingAscendantID ?? manifest.ascendants.first?.id
    }
}
