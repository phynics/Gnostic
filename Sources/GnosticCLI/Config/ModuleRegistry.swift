// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// One module entry in `Documentation/Architecture/experiments.json`.
///
/// The registry is the versioned machine-readable module record defined by ADR
/// 0013. `make docs-check` validates it against the compiled descriptors, so a
/// configuration console can read it to report lifecycle state without
/// duplicating that state in Swift.
public struct ModuleRegistryEntry: Codable, Sendable, Equatable {
    /// The registry id, for example `GNO-MOD-ATLAS`.
    public let id: String
    /// The human-readable module name.
    public let name: String
    /// The `Package.swift` targets the module adds.
    public let targets: [String]
    /// The lifecycle status: `incubating`, `gated`, `promoted`, `parked`, or `archived`.
    public let status: String
    /// The issue that owns the module.
    public let owningIssue: String
    /// The issues that gate promotion.
    public let gateIssues: [String]
    /// Whether a manifest can run the module.
    public let runnable: Bool
    /// The UTC date by which the entry needs review.
    public let reviewBy: String

    /// Creates one registry entry.
    public init(
        id: String,
        name: String,
        targets: [String] = [],
        status: String,
        owningIssue: String,
        gateIssues: [String] = [],
        runnable: Bool = false,
        reviewBy: String
    ) {
        self.id = id
        self.name = name
        self.targets = targets
        self.status = status
        self.owningIssue = owningIssue
        self.gateIssues = gateIssues
        self.runnable = runnable
        self.reviewBy = reviewBy
    }

    /// Whether the status is one a warning should accompany when selected.
    ///
    /// An `incubating` module is still changing, and a `parked` module has no
    /// active owner. Selecting either is allowed, but the operator is told.
    public var isCautionary: Bool { status == "incubating" || status == "parked" }
}

/// The decoded `experiments.json` module registry.
public struct ModuleRegistry: Codable, Sendable, Equatable {
    /// The registry schema version.
    public let schemaVersion: Int
    /// Every module entry.
    public let modules: [ModuleRegistryEntry]

    /// Creates one registry.
    public init(schemaVersion: Int = 1, modules: [ModuleRegistryEntry]) {
        self.schemaVersion = schemaVersion
        self.modules = modules
    }

    /// The entry with one id, when present.
    ///
    /// - Parameter id: The registry id.
    /// - Returns: The entry, or `nil`.
    public func entry(id: String) -> ModuleRegistryEntry? {
        modules.first { $0.id == id }
    }

    /// The entry for a compiled module's optional registry id.
    ///
    /// - Parameter id: A descriptor's `registryID`.
    /// - Returns: The entry, or `nil` when the id is absent or the descriptor has none.
    public func entry(forRegistryID id: String?) -> ModuleRegistryEntry? {
        guard let id else { return nil }
        return entry(id: id)
    }

    /// The path of the registry relative to a repository root.
    public static func path(relativeTo root: URL) -> URL {
        root.appendingPathComponent("Documentation/Architecture/experiments.json")
    }

    /// Loads the registry from a repository root.
    ///
    /// - Parameter root: The repository root that holds `Documentation/`.
    /// - Returns: The decoded registry.
    /// - Throws: A decoding or file error when the registry is absent or malformed.
    public static func load(relativeTo root: URL) throws -> ModuleRegistry {
        let data = try Data(contentsOf: path(relativeTo: root))
        return try JSONDecoder().decode(ModuleRegistry.self, from: data)
    }
}
