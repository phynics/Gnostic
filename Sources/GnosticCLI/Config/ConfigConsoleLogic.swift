// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore

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
        case let .invalidProject(id):
            path = "timelines[\(id.uuidString.lowercased())].project"
            hint = "Use a local Project with an absolute path, or a scratch Project without a path."
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
