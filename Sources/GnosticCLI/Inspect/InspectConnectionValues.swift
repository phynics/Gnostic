// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

public struct InspectConnectionValues: Sendable {
    public var host: String?
    public var port: Int?
    public var namespace: String?
    public var observeSeconds: Double

    public init(host: String? = nil, port: Int? = nil, namespace: String? = nil, observeSeconds: Double = 1.0) {
        self.host = host
        self.port = port
        self.namespace = namespace
        self.observeSeconds = observeSeconds
    }
}

/// Bounded broker observation: connect, subscribe to canonical Gnostic types,
/// collect a deterministic snapshot within a deadline, then disconnect.
