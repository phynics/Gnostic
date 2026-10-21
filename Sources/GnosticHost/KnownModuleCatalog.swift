// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticCore

/// The registry identity of every module whose provider-specific execution
/// remains in the temporary legacy composition target.
///
/// The clean host knows the names and the registry identities, so config and
/// doctor can report an existing manifest without loading PositronicKit into
/// the host process. The clean host executes none of them.
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
