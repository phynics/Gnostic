// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The raw Axoloty wire family observed by ``GnosticConsumerSession/rawEvents()``.
///
/// This is diagnostic vocabulary, not a stable automation contract. The cases
/// name the Axoloty families a consumer session can observe on its own
/// connection.
public enum GnosticRawWireEventKind: String, Codable, Sendable, Equatable, CaseIterable {
    case advertise
    case deadvertise
    case discover
    case resolve
    case query
    case retrieve
    case update
    case complete
    case call
    case returnEvent
    case channel
}

/// A bounded, diagnostic view of one raw wire event seen by a consumer session.
///
/// The envelope carries only Gnostic-owned values. It is intentionally
/// read-only and best-effort: the session projects events from its existing
/// bounded runtime streams, drops the oldest event when an observer falls
/// behind, and never persists or replays them. Do not build automation on
/// ``GnosticConsumerSession/rawEvents()``; use the typed clients instead.
public struct GnosticRawWireEvent: Codable, Sendable, Equatable {
    /// The maximum UTF-8 byte length retained in ``payload``.
    ///
    /// The value is the shared embedded-value budget, so one raw event can
    /// never exceed the bounded size a Gnostic operation already accepts.
    public static let maximumPayloadBytes = GnosticWirePayload.maximumEmbeddedValueBytes

    /// The Axoloty wire family.
    public let kind: GnosticRawWireEventKind

    /// The sending identity, when the event carries one.
    public let sourceId: String?

    /// The request correlation identity, when the family carries one.
    public let correlationId: String?

    /// The object type named by the event, when one is derivable.
    public let objectType: String?

    /// The object identity the event addresses, when one is derivable.
    public let targetObjectId: UUID?

    /// The semantic channel identifier, when the event arrived on a channel.
    public let channelId: String?

    /// The bounded raw wire payload, truncated on a Unicode scalar boundary.
    public let payload: String

    /// Creates a raw wire event, bounding the payload to ``maximumPayloadBytes``.
    ///
    /// - Parameters:
    ///   - kind: The Axoloty wire family.
    ///   - sourceId: The sending identity, or `nil`.
    ///   - correlationId: The request correlation identity, or `nil`.
    ///   - objectType: The object type named by the event, or `nil`.
    ///   - targetObjectId: The addressed object identity, or `nil`.
    ///   - channelId: The semantic channel identifier, or `nil`.
    ///   - payload: The raw wire payload; longer values are truncated.
    public init(
        kind: GnosticRawWireEventKind,
        sourceId: String? = nil,
        correlationId: String? = nil,
        objectType: String? = nil,
        targetObjectId: UUID? = nil,
        channelId: String? = nil,
        payload: String
    ) {
        self.kind = kind
        self.sourceId = sourceId
        self.correlationId = correlationId
        self.objectType = objectType
        self.targetObjectId = targetObjectId
        self.channelId = channelId
        self.payload = GnosticWirePayload.prefix(payload, maximumBytes: Self.maximumPayloadBytes)
    }
}
