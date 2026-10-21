// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticCore

/// Clean metadata for modules whose provider-specific execution remains in the
/// temporary legacy composition target.
///
/// Keeping the names and registry identities visible lets config and doctor
/// report existing manifests without loading PositronicKit into the host.
enum LegacyModuleCatalog {
    static let atlas = GnosticModule(
        name: "atlas",
        registryID: "GNO-MOD-ATLAS"
    )

    static let rlm = GnosticModule(
        name: "rlm",
        registryID: "GNO-MOD-RLM",
        settingKeys: [
            .init(name: "worker", summary: "Bounded Scheme worker to use: guile or chibi."),
        ],
        requiresModelService: true,
        experimentSubcommand: .init(
            name: "rlm-scenario",
            abstract: "Run the RLM scenario live stages (pilot or full matrix) against a configured provider."
        )
    )
}
