// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

public struct InspectConnectionValues: Sendable {
    public var host: String?
    public var port: Int?
    public var namespace: String?
    public var observeSeconds: Double
    /// The Node manifest to resolve broker defaults from, or `nil` for the default store.
    public var configPath: URL?

    public init(
        host: String? = nil,
        port: Int? = nil,
        namespace: String? = nil,
        observeSeconds: Double = 1.0,
        configPath: URL? = nil
    ) {
        self.host = host
        self.port = port
        self.namespace = namespace
        self.observeSeconds = observeSeconds
        self.configPath = configPath
    }
}

/// Bounded broker observation: connect, subscribe to canonical Gnostic types,
/// collect a deterministic snapshot within a deadline, then disconnect.
