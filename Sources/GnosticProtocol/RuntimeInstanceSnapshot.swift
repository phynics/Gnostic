// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Current process health for one discovered Runtime instance.
public enum GnosticRuntimeInstanceHealth: String, Codable, Sendable, Equatable {
    case healthy
    case failed
    case unknown
}

/// An immutable snapshot of a Runtime instance as its Node advertised it.
///
/// The snapshot carries the Runtime's own ACP identity and launch fingerprint
/// for routing and diagnostics, as defined by ADR 0021. It is a value: a
/// consumer can pass it between actors without synchronization. Read it from
/// ``NetworkCatalogEntry/runtimeInstance``.
public struct RuntimeInstanceSnapshot: Sendable, Equatable {
    /// The Runtime instance identifier.
    public let id: UUID

    /// The instance name, truncated to the label bound.
    public let name: String

    /// The protocol major the advertisement carries.
    public let protocolMajor: Int

    /// The identity of the Node that hosts the instance, when the Node sent it.
    public let nodeID: UUID?

    /// The kind of Runtime, for example the name of its executable.
    public let runtimeKind: String

    /// The Runtime's version, once its ACP `initialize` answer arrived.
    public let runtimeVersion: String?

    /// The launch fingerprint of the supervised Runtime process.
    public let launchFingerprint: String?

    /// The process health the Node reported.
    public let health: GnosticRuntimeInstanceHealth

    /// The capabilities from the Runtime's ACP `initialize` answer, unparsed.
    public let rawCapabilities: [String: GnosticJSONValue]

    /// Creates a Runtime instance snapshot.
    public init(
        id: UUID,
        name: String,
        protocolMajor: Int = GnosticProtocol.currentMajor,
        nodeID: UUID? = nil,
        runtimeKind: String,
        runtimeVersion: String? = nil,
        launchFingerprint: String? = nil,
        health: GnosticRuntimeInstanceHealth = .unknown,
        rawCapabilities: [String: GnosticJSONValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.protocolMajor = protocolMajor
        self.nodeID = nodeID
        self.runtimeKind = runtimeKind
        self.runtimeVersion = runtimeVersion
        self.launchFingerprint = launchFingerprint
        self.health = health
        self.rawCapabilities = rawCapabilities
    }
}
