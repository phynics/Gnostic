// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticHost
import GnosticKit

/// The registry status shown when a compiled module has no `experiments.json` entry.
public let unregisteredModuleStatus = "unregistered"

/// One configuration key a module contributes, in its full namespaced form.
public struct ModuleSettingKey: Codable, Sendable, Equatable {
    /// The key as stored in the backend envelope, for example `rlm.worker`.
    public let name: String
    /// The module-local key name, for example `worker`.
    public let localName: String
    /// A one-line description.
    public let summary: String
    /// Whether the value is a secret and must be redacted.
    public let isSecret: Bool

    /// Creates one module key view.
    public init(name: String, localName: String, summary: String, isSecret: Bool) {
        self.name = name
        self.localName = localName
        self.summary = summary
        self.isSecret = isSecret
    }
}

/// One compiled-in module as the configuration console reports it.
public struct ModuleConsoleEntry: Codable, Sendable, Equatable {
    /// The static selection name used in `extensions`.
    public let name: String
    /// The `experiments.json` registry id, when present.
    public let registryID: String?
    /// The registry lifecycle status, or ``unregisteredModuleStatus``.
    public let status: String
    /// The registry's human-readable name, when present.
    public let registryName: String?
    /// Whether the registry entry is runnable from a manifest.
    public let runnable: Bool?
    /// The registry owning issue URL, when present.
    public let owningIssue: String?
    /// Whether the module installs a Positronic contribution.
    public let installsContribution: Bool
    /// Whether a dedicated model service is required at runtime.
    public let requiresModelService: Bool
    /// The module's namespaced settings keys.
    public let keys: [ModuleSettingKey]
    /// A warning to show when the entry is cautionary, otherwise `nil`.
    public let warning: String?

    /// Creates one module console entry.
    public init(
        name: String,
        registryID: String?,
        status: String,
        registryName: String?,
        runnable: Bool?,
        owningIssue: String?,
        installsContribution: Bool,
        requiresModelService: Bool,
        keys: [ModuleSettingKey],
        warning: String?
    ) {
        self.name = name
        self.registryID = registryID
        self.status = status
        self.registryName = registryName
        self.runnable = runnable
        self.owningIssue = owningIssue
        self.installsContribution = installsContribution
        self.requiresModelService = requiresModelService
        self.keys = keys
        self.warning = warning
    }
}

/// The result of enabling or disabling one module on one Ascendant.
public struct ModuleMutation: Codable, Sendable, Equatable {
    /// The Ascendant whose selection changed.
    public let ascendantID: UUID
    /// The module selection name.
    public let module: String
    /// Whether the module is now selected.
    public let enabled: Bool
    /// Warnings emitted because the module's registry status is cautionary.
    public let warnings: [String]

    /// Creates one mutation result.
    public init(ascendantID: UUID, module: String, enabled: Bool, warnings: [String]) {
        self.ascendantID = ascendantID
        self.module = module
        self.enabled = enabled
        self.warnings = warnings
    }
}

/// One validation problem with a manifest path and a remediation hint.
public struct ValidationIssue: Codable, Sendable, Equatable {
    /// The manifest path the problem belongs to, for example `ascendants[<id>].backend`.
    public let path: String
    /// The stable machine-readable reason label.
    public let reasonCode: String
    /// The human-readable failure.
    public let message: String
    /// A suggested correction.
    public let hint: String

    /// Creates one validation issue.
    public init(path: String, reasonCode: String, message: String, hint: String) {
        self.path = path
        self.reasonCode = reasonCode
        self.message = message
        self.hint = hint
    }
}

/// The structured result of `config validate`.
public struct ValidationReport: Codable, Sendable, Equatable {
    /// Whether the manifest is valid.
    public let valid: Bool
    /// The manifest file the report describes.
    public let path: String
    /// Every problem found. Empty when `valid` is true.
    public let issues: [ValidationIssue]

    /// Creates one validation report.
    public init(valid: Bool, path: String, issues: [ValidationIssue]) {
        self.valid = valid
        self.path = path
        self.issues = issues
    }
}

/// The configuration console's shared logic.
///
/// Every method is pure with respect to the composition and the registry it is
/// handed, so a test can exercise the console without a broker, a provider, or
/// a network call. Listing never constructs a backend or a language model.
public enum ConfigConsoleLogic {
    // MARK: Modules

    /// Lists every compiled-in module with its registry state.
    ///
    /// Registry-only entries (for example a parked module with no compiled
    /// target) are appended after the compiled modules, so an operator sees
    /// both what is buildable and what the registry tracks.
    ///
    /// - Parameters:
    ///   - composition: The compiled composition source.
    ///   - registry: The registry, or `nil` when it could not be read.
    /// - Returns: Compiled modules first, then registry-only entries.
    public static func modules(
        composition: BackendComposition = .default,
        registry: ModuleRegistry?
    ) -> [ModuleConsoleEntry] {
        let compiled = composition.moduleDescriptors.map { module in
            entry(for: module, composition: composition, registry: registry)
        }
        let compiledIDs = Set(compiled.compactMap(\.registryID))
        let compiledNames = Set(compiled.map(\.name))
        let registryOnly = (registry?.modules ?? [])
            .filter { !compiledIDs.contains($0.id) && !compiledNames.contains($0.name) }
            .sorted { $0.id < $1.id }
            .map { entry(for: $0) }
        return compiled + registryOnly
    }

    private static func entry(
        for module: GnosticModule,
        composition: BackendComposition,
        registry: ModuleRegistry?
    ) -> ModuleConsoleEntry {
        let registryEntry = registry?.entry(id: module.registryID ?? "")
        let status = registryEntry?.status ?? unregisteredModuleStatus
        let keys = module.settingKeys.map { key in
            ModuleSettingKey(
                name: "\(module.name).\(key.name)",
                localName: key.name,
                summary: key.summary,
                isSecret: key.isSecret
            )
        }
        return ModuleConsoleEntry(
            name: module.name,
            registryID: module.registryID,
            status: status,
            registryName: registryEntry?.name,
            runnable: registryEntry?.runnable,
            owningIssue: registryEntry?.owningIssue,
            installsContribution: module.contribution != nil,
            requiresModelService: module.requiresModelService,
            keys: keys,
            warning: warning(module: module.name, entry: registryEntry)
        )
    }

    private static func entry(for entry: ModuleRegistryEntry) -> ModuleConsoleEntry {
        ModuleConsoleEntry(
            name: entry.id,
            registryID: entry.id,
            status: entry.status,
            registryName: entry.name,
            runnable: entry.runnable,
            owningIssue: entry.owningIssue,
            installsContribution: false,
            requiresModelService: false,
            keys: [],
            warning: warning(module: entry.id, entry: entry)
        )
    }

    private static func warning(module: String, entry: ModuleRegistryEntry?) -> String? {
        guard let entry, entry.isCautionary else { return nil }
        return "Module '\(module)' is \(entry.status). Selecting it is allowed, but it is not promoted."
    }

    /// Enables one module on one Ascendant.
    ///
    /// - Parameters:
    ///   - ascendantID: The Ascendant UUID.
    ///   - module: The static module name.
    ///   - store: The manifest store.
    ///   - composition: The compiled composition source.
    ///   - registry: The registry, or `nil` when it cannot be read.
    /// - Returns: The mutation result, including cautionary warnings.
    /// - Throws: A configuration error when the Ascendant, backend kind, or
    ///   module is not selectable.
    @discardableResult
    public static func enableModule(
        ascendantID: String,
        module: String,
        store: CLIConfigurationStore,
        composition: BackendComposition = .default,
        registry: ModuleRegistry? = nil
    ) throws -> ModuleMutation {
        try mutateModule(ascendantID: ascendantID, module: module, enable: true, store: store, composition: composition, registry: registry, mutation: { backend in
            var selected = Self.selectedNames(in: backend)
            guard !selected.contains(module) else { return false }
            selected.append(module)
            backend.settings["extensions"] = .array(selected.map(ManifestJSONValue.string))
            return true
        })
    }

    /// Disables one module on one Ascendant.
    ///
    /// - Parameters:
    ///   - ascendantID: The Ascendant UUID.
    ///   - module: The static module name.
    ///   - store: The manifest store.
    ///   - composition: The compiled composition source.
    ///   - registry: The registry, or `nil` when it cannot be read.
    /// - Returns: The mutation result.
    /// - Throws: A configuration error when the Ascendant or backend kind is
    ///   not selectable. Disabling a module that is not selected is a no-op.
    @discardableResult
    public static func disableModule(
        ascendantID: String,
        module: String,
        store: CLIConfigurationStore,
        composition: BackendComposition = .default,
        registry: ModuleRegistry? = nil
    ) throws -> ModuleMutation {
        try mutateModule(ascendantID: ascendantID, module: module, enable: false, store: store, composition: composition, registry: registry, mutation: { backend in
            var selected = Self.selectedNames(in: backend)
            guard selected.contains(module) else { return false }
            selected.removeAll { $0 == module }
            if selected.isEmpty {
                backend.settings.removeValue(forKey: "extensions")
            } else {
                backend.settings["extensions"] = .array(selected.map(ManifestJSONValue.string))
            }
            return true
        })
    }

    private static func mutateModule(
        ascendantID: String,
        module: String,
        enable: Bool,
        store: CLIConfigurationStore,
        composition: BackendComposition,
        registry: ModuleRegistry?,
        mutation: (inout NodeManifest.BackendConfiguration) -> Bool
    ) throws -> ModuleMutation {
        guard let id = UUID(uuidString: ascendantID) else {
            throw CLIConfigurationError.invalidArgument("Invalid ascendant UUID '\(ascendantID)'.")
        }
        guard composition.moduleDescriptor(named: module) != nil else {
            let known = composition.moduleDescriptors.map(\.name).sorted()
            throw CLIConfigurationError.invalidArgument(
                "Unknown module '\(module)'. Known modules: \(known.isEmpty ? "none" : known.joined(separator: ", "))."
            )
        }
        var warningMessage: String?
        _ = try store.mutateManifest { manifest in
            guard let index = manifest.ascendants.firstIndex(where: { $0.id == id }) else {
                throw CLIConfigurationError.resourceNotFound(kind: "ascendant", id: id)
            }
            guard manifest.ascendants[index].backend.kind == AscendantAdapterRegistry.positronicKind else {
                throw CLIConfigurationError.invalidArgument(
                    "Module selection applies to the '\(AscendantAdapterRegistry.positronicKind)' backend kind, but this Ascendant uses '\(manifest.ascendants[index].backend.kind)'."
                )
            }
            let warnings = enable ? Self.warnings(for: module, registryID: composition.moduleDescriptor(named: module)?.registryID, registry: registry) : []
            warningMessage = warnings.first
            _ = mutation(&manifest.ascendants[index].backend)
        }
        return ModuleMutation(ascendantID: id, module: module, enabled: enable, warnings: warningMessage.map { [$0] } ?? [])
    }

    private static func warnings(for module: String, registryID: String?, registry: ModuleRegistry?) -> [String] {
        guard let entry = registry?.entry(forRegistryID: registryID), entry.isCautionary else { return [] }
        return ["Module '\(module)' is \(entry.status). Selecting it is allowed, but it is not promoted."]
    }

    /// Reads the `extensions` selection from one backend envelope.
    ///
    /// - Parameter backend: The Positronic backend envelope.
    /// - Returns: The selected names, preserving order. A malformed value yields `[]`.
    public static func selectedNames(in backend: NodeManifest.BackendConfiguration) -> [String] {
        guard case let .array(items) = backend.settings["extensions"] else { return [] }
        return items.compactMap(\.stringValue)
    }

    /// Lists the settings keys for the modules one Ascendant selects.
    ///
    /// - Parameters:
    ///   - ascendantID: The Ascendant UUID.
    ///   - store: The manifest store.
    ///   - composition: The compiled composition source.
    /// - Returns: One group per selected module, in selection order.
    /// - Throws: A configuration error when the Ascendant is absent.
    public static func moduleKeys(
        ascendantID: String,
        store: CLIConfigurationStore,
        composition: BackendComposition = .default
    ) throws -> [ModuleConsoleEntry] {
        let manifest = try store.loadManifest()
        guard let id = UUID(uuidString: ascendantID) else {
            throw CLIConfigurationError.invalidArgument("Invalid ascendant UUID '\(ascendantID)'.")
        }
        guard let ascendant = manifest.ascendants.first(where: { $0.id == id }) else {
            throw CLIConfigurationError.resourceNotFound(kind: "ascendant", id: id)
        }
        return try composition.selectedModuleNames(for: ascendant).compactMap { name in
            guard let module = composition.moduleDescriptor(named: name) else { return nil }
            return entry(for: module, composition: composition, registry: nil)
        }
    }

    // MARK: Regime

    /// Builds the resolved Regime for one Ascendant.
    ///
    /// The resolution lives in ``RegimeResolver`` (GnosticHost), which every
    /// experiment command also uses, so the shown Regime cannot drift from the
    /// one a run records. Secret values are never part of the value.
    ///
    /// - Parameters:
    ///   - ascendantID: The Ascendant UUID.
    ///   - store: The manifest store.
    ///   - composition: The compiled composition source.
    /// - Returns: The Regime value the run/export surface consumes.
    /// - Throws: A configuration error when the Ascendant is absent.
    public static func regime(
        ascendantID: String,
        store: CLIConfigurationStore,
        composition: BackendComposition = .default
    ) throws -> ExperimentRegime {
        let manifest = try store.loadManifest()
        guard let id = UUID(uuidString: ascendantID) else {
            throw CLIConfigurationError.invalidArgument("Invalid ascendant UUID '\(ascendantID)'.")
        }
        do {
            return try RegimeResolver.resolve(ascendantID: id, manifest: manifest, composition: composition)
        } catch let RegimeResolutionError.ascendantNotFound(missing) {
            throw CLIConfigurationError.resourceNotFound(kind: "ascendant", id: missing)
        }
    }

    // MARK: Validation

    /// Validates the manifest and returns every problem with a hint.
    ///
    /// - Parameter store: The manifest store.
    /// - Returns: A report whose `valid` flag is false when any problem exists.
    public static func validationReport(store: CLIConfigurationStore) -> ValidationReport {
        let path = store.path().path
        let manifest: NodeManifest
        do {
            manifest = try store.loadManifest()
        } catch let error as CLIConfigurationError {
            return ValidationReport(valid: false, path: path, issues: issues(for: error, path: path))
        } catch {
            return ValidationReport(
                valid: false,
                path: path,
                issues: [ValidationIssue(path: path, reasonCode: "unreadable", message: error.localizedDescription, hint: "Recreate the manifest with `gnostic config init`.")]
            )
        }
        do {
            try manifest.validate()
            try manifest.validateBrokerCredentials()
            return ValidationReport(valid: true, path: path, issues: [])
        } catch let error as NodeManifestError {
            return ValidationReport(valid: false, path: path, issues: [issue(for: error)])
        } catch {
            return ValidationReport(
                valid: false,
                path: path,
                issues: [ValidationIssue(path: path, reasonCode: "invalidManifest", message: error.localizedDescription, hint: "Correct the manifest and run `gnostic config validate` again.")]
            )
        }
    }

    private static func issues(for error: CLIConfigurationError, path: String) -> [ValidationIssue] {
        switch error {
        case .missingFile:
            return [ValidationIssue(path: path, reasonCode: "missingFile", message: "No manifest exists at \(path).", hint: "Run `gnostic config init`.")]
        case .malformedFile:
            return [ValidationIssue(path: path, reasonCode: "malformedFile", message: "The manifest at \(path) is not valid JSON.", hint: "Restore the file or recreate it with `gnostic config init`.")]
        case let .invalidManifest(manifestError, _):
            return [issue(for: manifestError)]
        default:
            return [ValidationIssue(path: path, reasonCode: error.reasonCode, message: error.localizedDescription, hint: "Correct the manifest and run `gnostic config validate` again.")]
        }
    }

    private static func issue(for error: NodeManifestError) -> ValidationIssue {
        let path: String
        let hint: String
        switch error {
        case .unsupportedSchemaVersion:
            path = "schemaVersion"
            hint = "Recreate the manifest with `gnostic config init`, or migrate it with Gnostic 0.4."
        case .invalidBroker:
            path = "broker"
            hint = "Set a non-empty host and namespace and a port between 1 and 65535."
        case .passwordWithoutUsername:
            path = "broker.password"
            hint = "Set `broker.username`, or clear `broker.password` with `config broker set-password` and empty input."
        case .invalidNodeSettings:
            path = "node"
            hint = "Set `node.approvalMode` to auto or deny, and `node.logLevel` to trace, debug, info, warning, or error."
        case let .invalidUUID(id):
            path = id.uuidString.lowercased()
            hint = "Assign a version 4 RFC 4122 UUID."
        case let .invalidKind(_, id):
            path = id.uuidString.lowercased()
            hint = "Set a non-empty kind and name for this object."
        case let .invalidBackend(id):
            path = "ascendants[\(id.uuidString.lowercased())].backend"
            hint = "Clear and reconfigure the backend envelope with `config backend`."
        case let .invalidAttachment(id):
            path = "timelines[\(id.uuidString.lowercased())].attachments"
            hint = "Detach and reattach the Workspace, or set a non-empty URI for a network attachment."
        case let .duplicateID(id):
            path = id.uuidString.lowercased()
            hint = "Give every Node, Ascendant, Timeline, and Workspace a unique UUID."
        case let .duplicateAttachment(timeline, workspace):
            path = "timelines[\(timeline.uuidString.lowercased())].attachments[\(workspace.uuidString.lowercased())]"
            hint = "Detach the duplicate Workspace attachment."
        case let .missingReference(from, to):
            path = "\(from.uuidString.lowercased()) -> \(to.uuidString.lowercased())"
            hint = "Create the referenced object or update the reference."
        case let .invalidDefaultTimeline(ascendant, _):
            path = "ascendants[\(ascendant.uuidString.lowercased())].defaultTimelineID"
            hint = "Point the Ascendant at a Timeline it operates."
        case let .immutableIdentity(id):
            path = id.uuidString.lowercased()
            hint = "Remove and recreate the object instead of changing its ID or kind."
        }
        return ValidationIssue(path: path, reasonCode: error.reasonCode, message: error.errorDescription ?? error.reasonCode, hint: hint)
    }

    // MARK: Dry run

    /// Applies a mutating configuration operation, or previews it.
    ///
    /// With `dryRun` false this calls `apply` against the real store. With
    /// `dryRun` true it applies `apply` to a temporary copy, renders the
    /// redacted diff, and discards the copy, so the real manifest is unchanged.
    ///
    /// - Parameters:
    ///   - store: The real manifest store.
    ///   - dryRun: Whether to preview instead of write.
    ///   - apply: The mutation, parameterized by the store it should use.
    ///   - writeOutput: Receives the diff, or each mutation's normal output.
    /// - Throws: A configuration error from the mutation.
    public static func applyMutation(
        store: CLIConfigurationStore,
        dryRun: Bool,
        apply: (CLIConfigurationStore) throws -> Void,
        writeOutput: (String) -> Void = { print($0) }
    ) throws {
        guard dryRun else {
            try apply(store)
            return
        }
        let preview = try store.previewManifest()
        defer { preview.discard() }
        try apply(preview.store)
        let before = try store.loadManifestOrEmpty()
        let after = try preview.store.loadManifestOrEmpty()
        writeOutput(ManifestDiff.render(before: before, after: after))
    }
}
