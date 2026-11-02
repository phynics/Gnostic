// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticACPWire

/// An ACP `session/update` notification as the Runtime sent it.
///
/// ADR 0021 requires the Timeline journal to store ACP updates exactly as
/// received. A decoded value cannot do that. A known kind decodes into a type
/// that drops unmodeled fields, and even a generic JSON value changes number
/// text, collapses duplicate keys, loses key order, and cannot always be
/// encoded again. This value therefore keeps the text of the received frame,
/// which is one line of JSON-RPC, and projects the typed update from it.
///
/// The journal stores the frame as a JSON string, which has no nesting depth
/// and is not re-encoded. An update that the earlier journal shape stored as a
/// JSON object also reads as this type, with no frame.
///
/// This type lives in `GnosticCore`, outside the stable products, because it
/// carries an ACP wire value.
public struct ReceivedACPUpdate: Codable, Sendable, Equatable {
    private enum Storage: Sendable, Equatable {
        /// The received frame text and its typed projection.
        case frame(String, update: ACPSessionUpdate?)
        /// An update stored in the earlier typed shape.
        case typed(ACPSessionUpdate)
    }

    private let storage: Storage

    /// The exact text of the received `session/update` line, without its newline.
    ///
    /// It is `nil` for an update that the earlier journal shape stored as a typed object.
    public var frame: String? {
        guard case let .frame(text, _) = storage else { return nil }
        return text
    }

    /// The typed projection, which drives Gnostic's own consumers.
    ///
    /// It is `nil` when the frame does not fit the fixed ACP type of its update
    /// kind, or when `update` is not an object with a `sessionUpdate`. Consumers skip such an
    /// update. The frame is then the only record of it.
    public var update: ACPSessionUpdate? {
        switch storage {
        case let .frame(_, update): update
        case let .typed(update): update
        }
    }

    /// Wraps an update that exists only in its typed form.
    public init(_ update: ACPSessionUpdate) {
        storage = .typed(update)
    }

    /// Wraps the exact text of a received `session/update` line.
    public init(frame: String) {
        storage = .frame(frame, update: Self.projection(of: frame))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self.init(frame: text)
        } else {
            self.init(try container.decode(ACPSessionUpdate.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch storage {
        case let .frame(text, _): try container.encode(text)
        case let .typed(update): try container.encode(update)
        }
    }

    /// Decodes the frame's `params.update` strictly, as the Runtime transport always has.
    private static func projection(of frame: String) -> ACPSessionUpdate? {
        // The frame text keeps a leading byte order mark. The decoder does not need it.
        var bytes = Data(frame.utf8)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = Data(bytes.dropFirst(3)) }
        return try? JSONDecoder().decode(Envelope.self, from: bytes).params?.update
    }

    private struct Envelope: Decodable {
        let params: ACPSessionNotification?

        private enum CodingKeys: String, CodingKey { case params }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            params = try? container.decode(ACPSessionNotification.self, forKey: .params)
        }
    }
}
