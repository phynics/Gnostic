// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A length-prefixed worker frame.
///
/// Every frame carries the run identity. Frames are encoded as one restricted
/// S-expression so the parent's parser is the single value authority.
public enum RLMSchemeWorkerFrame: Sendable, Equatable {
    case initialize(RLMSchemeInitialize)
    case evaluate(RLMSchemeEvaluate)
    case hostResult(RLMSchemeHostResult)
    case hostError(RLMSchemeHostError)
    case cancel(runID: String)
    case shutdown(runID: String)
    case ready(RLMSchemeReady)
    case hostCall(RLMSchemeHostCall)
    case evaluated(RLMSchemeEvaluated)
    case finished(RLMSchemeFinished)
    case failed(RLMSchemeEvaluationFailure)

    public var runID: String {
        switch self {
        case let .initialize(frame): return frame.runID
        case let .evaluate(frame): return frame.runID
        case let .hostResult(frame): return frame.runID
        case let .hostError(frame): return frame.runID
        case let .cancel(runID): return runID
        case let .shutdown(runID): return runID
        case let .ready(frame): return frame.runID
        case let .hostCall(frame): return frame.runID
        case let .evaluated(frame): return frame.runID
        case let .finished(frame): return frame.runID
        case let .failed(frame): return frame.runID
        }
    }
}

public struct RLMSchemeInitialize: Sendable, Equatable {
    public let runID: String
    public let profile: String
    public let maxHeapBytes: Int
    public let maxOutputBytes: Int
    public let timeLimitSeconds: Double
    public let allocationLimitBytes: Int

    public init(
        runID: String,
        profile: String,
        maxHeapBytes: Int,
        maxOutputBytes: Int,
        timeLimitSeconds: Double,
        allocationLimitBytes: Int
    ) {
        self.runID = runID
        self.profile = profile
        self.maxHeapBytes = maxHeapBytes
        self.maxOutputBytes = maxOutputBytes
        self.timeLimitSeconds = timeLimitSeconds
        self.allocationLimitBytes = allocationLimitBytes
    }
}

public struct RLMSchemeEvaluate: Sendable, Equatable {
    public let runID: String
    public let cellID: Int
    public let source: String

    public init(runID: String, cellID: Int, source: String) {
        self.runID = runID
        self.cellID = cellID
        self.source = source
    }
}

public struct RLMSchemeHostCall: Sendable, Equatable {
    public let runID: String
    public let callID: Int
    public let name: String
    public let arguments: [RLMSExpression]

    public init(runID: String, callID: Int, name: String, arguments: [RLMSExpression]) {
        self.runID = runID
        self.callID = callID
        self.name = name
        self.arguments = arguments
    }
}

public struct RLMSchemeHostResult: Sendable, Equatable {
    public let runID: String
    public let callID: Int
    public let value: RLMSExpression

    public init(runID: String, callID: Int, value: RLMSExpression) {
        self.runID = runID
        self.callID = callID
        self.value = value
    }
}

public struct RLMSchemeHostError: Sendable, Equatable {
    public let runID: String
    public let callID: Int
    public let message: String

    public init(runID: String, callID: Int, message: String) {
        self.runID = runID
        self.callID = callID
        self.message = message
    }
}

public struct RLMSchemeReady: Sendable, Equatable {
    public let runID: String
    public let environmentKeys: [String]
    public let openFileDescriptorCount: Int
    public let cpuLimitSeconds: Int
    public let addressSpaceBytes: Int

    public init(
        runID: String,
        environmentKeys: [String],
        openFileDescriptorCount: Int,
        cpuLimitSeconds: Int,
        addressSpaceBytes: Int
    ) {
        self.runID = runID
        self.environmentKeys = environmentKeys
        self.openFileDescriptorCount = openFileDescriptorCount
        self.cpuLimitSeconds = cpuLimitSeconds
        self.addressSpaceBytes = addressSpaceBytes
    }
}

public struct RLMSchemeEvaluated: Sendable, Equatable {
    public let runID: String
    public let cellID: Int
    public let value: RLMSExpression?
    public let output: String

    public init(runID: String, cellID: Int, value: RLMSExpression?, output: String) {
        self.runID = runID
        self.cellID = cellID
        self.value = value
        self.output = output
    }
}

public struct RLMSchemeFinished: Sendable, Equatable {
    public let runID: String
    public let answer: String
    public let evidenceIDs: [String]

    public init(runID: String, answer: String, evidenceIDs: [String]) {
        self.runID = runID
        self.answer = answer
        self.evidenceIDs = evidenceIDs
    }
}

public struct RLMSchemeEvaluationFailure: Sendable, Equatable {
    public let runID: String
    public let cellID: Int
    public let message: String

    public init(runID: String, cellID: Int, message: String) {
        self.runID = runID
        self.cellID = cellID
        self.message = message
    }
}

/// A protocol-level failure while framing or decoding a worker message.
public enum RLMSchemeProtocolError: Error, Sendable, Equatable, CustomStringConvertible {
    case frameTooLarge(limit: Int)
    case malformedFrame(String)
    case missingField(String)
    case unexpectedFieldType(String)
    case unknownFrameType(String)

    public var description: String {
        switch self {
        case let .frameTooLarge(limit):
            return "worker frame exceeds \(limit) bytes"
        case let .malformedFrame(reason):
            return "malformed worker frame: \(reason)"
        case let .missingField(field):
            return "missing worker frame field '\(field)'"
        case let .unexpectedFieldType(field):
            return "unexpected worker frame field type for '\(field)'"
        case let .unknownFrameType(type):
            return "unknown worker frame type '\(type)'"
        }
    }
}

/// Encodes and decodes length-prefixed worker frames.
public enum RLMSchemeWorkerCodec {
    public static let maxFrameBytes = 262_144

    /// Prefixes `payload` with its big-endian 32-bit byte length.
    public static func framed(_ payload: [UInt8]) throws -> [UInt8] {
        guard payload.count <= maxFrameBytes else {
            throw RLMSchemeProtocolError.frameTooLarge(limit: maxFrameBytes)
        }
        let length = UInt32(payload.count)
        var bytes: [UInt8] = [
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff),
        ]
        bytes.append(contentsOf: payload)
        return bytes
    }

    public static func encode(_ frame: RLMSchemeWorkerFrame) throws -> [UInt8] {
        try framed(Array(expression(for: frame).written.utf8))
    }

    public static func decode(_ payload: [UInt8]) throws -> RLMSchemeWorkerFrame {
        guard payload.count <= maxFrameBytes else {
            throw RLMSchemeProtocolError.frameTooLarge(limit: maxFrameBytes)
        }
        guard let text = String(validating: payload, as: UTF8.self) else {
            throw RLMSchemeProtocolError.malformedFrame("payload is not valid UTF-8")
        }
        let forms: [RLMSExpression]
        do {
            forms = try RLMSExpressionParser.parse(text)
        } catch {
            throw RLMSchemeProtocolError.malformedFrame("\(error)")
        }
        guard forms.count == 1 else {
            throw RLMSchemeProtocolError.malformedFrame("expected exactly one frame")
        }
        return try self.frame(from: forms[0])
    }

    public static func expression(for frame: RLMSchemeWorkerFrame) -> RLMSExpression {
        switch frame {
        case let .initialize(value):
            return .list([
                .symbol("initialize"),
                .symbol("runID"), .string(value.runID),
                .symbol("profile"), .string(value.profile),
                .symbol("maxHeapBytes"), .integer(value.maxHeapBytes),
                .symbol("maxOutputBytes"), .integer(value.maxOutputBytes),
                .symbol("timeLimitSeconds"), .double(value.timeLimitSeconds),
                .symbol("allocationLimitBytes"), .integer(value.allocationLimitBytes),
            ])
        case let .evaluate(value):
            return .list([
                .symbol("evaluate"),
                .symbol("runID"), .string(value.runID),
                .symbol("cellID"), .integer(value.cellID),
                .symbol("source"), .string(value.source),
            ])
        case let .hostResult(value):
            return .list([
                .symbol("hostResult"),
                .symbol("runID"), .string(value.runID),
                .symbol("callID"), .integer(value.callID),
                .symbol("value"), value.value,
            ])
        case let .hostError(value):
            return .list([
                .symbol("hostError"),
                .symbol("runID"), .string(value.runID),
                .symbol("callID"), .integer(value.callID),
                .symbol("message"), .string(value.message),
            ])
        case let .cancel(runID):
            return .list([.symbol("cancel"), .symbol("runID"), .string(runID)])
        case let .shutdown(runID):
            return .list([.symbol("shutdown"), .symbol("runID"), .string(runID)])
        case let .ready(value):
            return .list([
                .symbol("ready"),
                .symbol("runID"), .string(value.runID),
                .symbol("environmentKeys"), .list(value.environmentKeys.map { .string($0) }),
                .symbol("openFileDescriptorCount"), .integer(value.openFileDescriptorCount),
                .symbol("cpuLimitSeconds"), .integer(value.cpuLimitSeconds),
                .symbol("addressSpaceBytes"), .integer(value.addressSpaceBytes),
            ])
        case let .hostCall(value):
            return .list([
                .symbol("hostCall"),
                .symbol("runID"), .string(value.runID),
                .symbol("callID"), .integer(value.callID),
                .symbol("name"), .string(value.name),
                .symbol("arguments"), .list(value.arguments),
            ])
        case let .evaluated(value):
            var elements: [RLMSExpression] = [
                .symbol("evaluated"),
                .symbol("runID"), .string(value.runID),
                .symbol("cellID"), .integer(value.cellID),
                .symbol("output"), .string(value.output),
            ]
            if let expression = value.value {
                elements.append(.symbol("value"))
                elements.append(expression)
            }
            return .list(elements)
        case let .finished(value):
            return .list([
                .symbol("finished"),
                .symbol("runID"), .string(value.runID),
                .symbol("answer"), .string(value.answer),
                .symbol("evidenceIDs"), .list(value.evidenceIDs.map { .string($0) }),
            ])
        case let .failed(value):
            return .list([
                .symbol("failed"),
                .symbol("runID"), .string(value.runID),
                .symbol("cellID"), .integer(value.cellID),
                .symbol("message"), .string(value.message),
            ])
        }
    }

    public static func frame(from expression: RLMSExpression) throws -> RLMSchemeWorkerFrame {
        guard case let .list(elements) = expression, let typeExpression = elements.first else {
            throw RLMSchemeProtocolError.malformedFrame("frame must be a list")
        }
        guard case let .symbol(type) = typeExpression else {
            throw RLMSchemeProtocolError.malformedFrame("frame type must be a symbol")
        }
        let fields = try self.fields(Array(elements.dropFirst()))
        switch type {
        case "initialize":
            return .initialize(RLMSchemeInitialize(
                runID: try string(fields, "runID"),
                profile: try string(fields, "profile"),
                maxHeapBytes: try integer(fields, "maxHeapBytes"),
                maxOutputBytes: try integer(fields, "maxOutputBytes"),
                timeLimitSeconds: try double(fields, "timeLimitSeconds"),
                allocationLimitBytes: try integer(fields, "allocationLimitBytes")
            ))
        case "evaluate":
            return .evaluate(RLMSchemeEvaluate(
                runID: try string(fields, "runID"),
                cellID: try integer(fields, "cellID"),
                source: try string(fields, "source")
            ))
        case "hostResult":
            return .hostResult(RLMSchemeHostResult(
                runID: try string(fields, "runID"),
                callID: try integer(fields, "callID"),
                value: try require(fields, "value")
            ))
        case "hostError":
            return .hostError(RLMSchemeHostError(
                runID: try string(fields, "runID"),
                callID: try integer(fields, "callID"),
                message: try string(fields, "message")
            ))
        case "cancel":
            return .cancel(runID: try string(fields, "runID"))
        case "shutdown":
            return .shutdown(runID: try string(fields, "runID"))
        case "ready":
            return .ready(RLMSchemeReady(
                runID: try string(fields, "runID"),
                environmentKeys: try stringList(fields, "environmentKeys"),
                openFileDescriptorCount: try integer(fields, "openFileDescriptorCount"),
                cpuLimitSeconds: try integer(fields, "cpuLimitSeconds"),
                addressSpaceBytes: try integer(fields, "addressSpaceBytes")
            ))
        case "hostCall":
            return .hostCall(RLMSchemeHostCall(
                runID: try string(fields, "runID"),
                callID: try integer(fields, "callID"),
                name: try string(fields, "name"),
                arguments: try list(fields, "arguments")
            ))
        case "evaluated":
            return .evaluated(RLMSchemeEvaluated(
                runID: try string(fields, "runID"),
                cellID: try integer(fields, "cellID"),
                value: fields["value"],
                output: try string(fields, "output")
            ))
        case "finished":
            return .finished(RLMSchemeFinished(
                runID: try string(fields, "runID"),
                answer: try string(fields, "answer"),
                evidenceIDs: try stringList(fields, "evidenceIDs")
            ))
        case "failed":
            return .failed(RLMSchemeEvaluationFailure(
                runID: try string(fields, "runID"),
                cellID: try integer(fields, "cellID"),
                message: try string(fields, "message")
            ))
        default:
            throw RLMSchemeProtocolError.unknownFrameType(type)
        }
    }

    private static func fields(_ elements: [RLMSExpression]) throws -> [String: RLMSExpression] {
        guard elements.count % 2 == 0 else {
            throw RLMSchemeProtocolError.malformedFrame("frame fields must be key/value pairs")
        }
        var result: [String: RLMSExpression] = [:]
        var index = 0
        while index < elements.count {
            guard case let .symbol(key) = elements[index] else {
                throw RLMSchemeProtocolError.malformedFrame("frame field key must be a symbol")
            }
            result[key] = elements[index + 1]
            index += 2
        }
        return result
    }

    private static func require(_ fields: [String: RLMSExpression], _ key: String) throws -> RLMSExpression {
        guard let value = fields[key] else {
            throw RLMSchemeProtocolError.missingField(key)
        }
        return value
    }

    private static func string(_ fields: [String: RLMSExpression], _ key: String) throws -> String {
        guard case let .string(value) = try require(fields, key) else {
            throw RLMSchemeProtocolError.unexpectedFieldType(key)
        }
        return value
    }

    private static func integer(_ fields: [String: RLMSExpression], _ key: String) throws -> Int {
        guard case let .integer(value) = try require(fields, key) else {
            throw RLMSchemeProtocolError.unexpectedFieldType(key)
        }
        return value
    }

    private static func double(_ fields: [String: RLMSExpression], _ key: String) throws -> Double {
        switch try require(fields, key) {
        case let .double(value): return value
        case let .integer(value): return Double(value)
        default: throw RLMSchemeProtocolError.unexpectedFieldType(key)
        }
    }

    private static func list(_ fields: [String: RLMSExpression], _ key: String) throws -> [RLMSExpression] {
        guard case let .list(value) = try require(fields, key) else {
            throw RLMSchemeProtocolError.unexpectedFieldType(key)
        }
        return value
    }

    private static func stringList(_ fields: [String: RLMSExpression], _ key: String) throws -> [String] {
        try list(fields, key).map { element in
            guard case let .string(value) = element else {
                throw RLMSchemeProtocolError.unexpectedFieldType(key)
            }
            return value
        }
    }
}
