// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation

/// The shared `--config` option for every command that reads the Node manifest.
///
/// Commands embed this group with `@OptionGroup` instead of declaring their own
/// option, so the flag spelling and help text stay identical everywhere and the
/// manifest store is a pure function of the parsed arguments.
struct ConfigPathOptions: ParsableArguments {
    @Option(name: .customLong("config"), help: "Path to the Node manifest (overrides GNOSTIC_CONFIG).")
    var configPath: String?

    init() {}

    /// The manifest store this option selects. Without a path, the store
    /// resolves `GNOSTIC_CONFIG` and then the default location.
    func store() -> CLIConfigurationStore {
        ConfigCommandLogic.store(for: configPath)
    }
}
