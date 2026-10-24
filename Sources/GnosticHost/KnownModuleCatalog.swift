// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticCore

/// Static module descriptors used for configuration and registry reporting.
///
/// The host does not execute provider-specific model loops. Experiments that
/// need one run behind an independent ACP Runtime process.
enum KnownModuleCatalog {
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
