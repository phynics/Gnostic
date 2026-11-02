// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticACPWire

/// An ACP `session/update` value as the Runtime sent it.
///
/// ADR 0021 requires the Timeline journal to store ACP updates exactly as
/// received. A known update kind decodes into a fixed-field type that drops
/// unmodeled fields, and a known kind whose payload does not fit its type does
/// not decode at all. This value keeps the typed projection for Gnostic's own
/// consumers and the received JSON for the journal.
///
/// The encoding is the received JSON object, so the journal layout is unchanged.
/// This type lives in `GnosticCore`, outside the stable products, because it
/// carries an ACP wire value.
public struct ReceivedACPUpdate: Codable, Sendable, Equatable {
    /// The typed projection. A known kind whose payload does not fit its type
    /// projects as `.other(sessionUpdate:fields:)`, which typed consumers skip.
    public let update: ACPSessionUpdate

    /// The received JSON object when `update` cannot reproduce it, else `nil`.
    ///
    /// Keeping this `nil` for a faithful projection gives one canonical value
    /// for one journal payload.
    public let receivedOverride: ACPValue?

    /// The JSON object that the journal stores for this update.
    public var receivedValue: ACPValue {
        receivedOverride ?? Self.encoded(update) ?? .null
    }

    /// Wraps an update that has no information beyond its typed form.
    public init(_ update: ACPSessionUpdate) {
        self.update = update
        self.receivedOverride = Optional<ACPValue>.none
    }

    /// Wraps the received JSON object.
    ///
    /// Returns `nil` when `received` is not an object with a string
    /// `sessionUpdate`, because there is no update kind to project.
    public init?(received: ACPValue) {
        guard case let .object(fields) = received,
              case let .string(kind)? = fields["sessionUpdate"] else { return nil }
        let typed = Self.strictlyDecoded(received)
            ?? .other(sessionUpdate: kind, fields: fields.filter { $0.key != "sessionUpdate" })
        self.update = typed
        // `ACPValue` is `ExpressibleByNilLiteral`, so a bare `nil` here would be `.null`.
        if Self.encoded(typed) == received {
            self.receivedOverride = Optional<ACPValue>.none
        } else {
            self.receivedOverride = received
        }
    }

    public init(from decoder: Decoder) throws {
        let received = try decoder.singleValueContainer().decode(ACPValue.self)
        guard let value = Self(received: received) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "An ACP update needs a string sessionUpdate"
            ))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(receivedValue)
    }

    /// The typed form, only when the received JSON fits its fixed type.
    public static func strictlyDecoded(_ received: ACPValue) -> ACPSessionUpdate? {
        guard let data = try? JSONEncoder().encode(received) else { return nil }
        return try? JSONDecoder().decode(ACPSessionUpdate.self, from: data)
    }

    private static func encoded(_ update: ACPSessionUpdate) -> ACPValue? {
        guard let data = try? JSONEncoder().encode(update) else { return nil }
        return try? JSONDecoder().decode(ACPValue.self, from: data)
    }
}
