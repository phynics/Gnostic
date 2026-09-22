// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A structured, host-owned failure for one RLM run.
///
/// Callers classify a failed run by matching the case instead of parsing a
/// message. Cell failures are bounded repair signals; all other cases are
/// terminal. No case carries provider secrets, corpus content, or model output.
public enum RLMFailure: Error, Sendable, Equatable, CustomStringConvertible {
    /// A host budget request contained a negative or otherwise invalid value.
    case invalidToolArguments(String)
    /// A path was empty, malformed, or otherwise not a relative Workspace path.
    case invalidPath(String)
    /// A path was absolute and could escape the selected Workspace.
    case absolutePathRejected(String)
    /// A path contained a `..` component.
    case parentTraversalRejected(String)
    /// A path was resolved outside the configured allowed prefixes.
    case pathOutsideAllowedPrefixes(String)
    /// The accepted file count exceeded the configured maximum.
    case tooManyFiles(limit: Int)
    /// The accepted corpus bytes exceeded the configured maximum.
    case corpusTooLarge(limit: Int)
    /// The corpus source failed for a reason other than a structured RLM failure.
    case corpusSourceFailed(String)
    /// The root iteration limit was reached.
    case rootIterationLimitReached(limit: Int)
    /// The leaf model call limit was reached.
    case leafCallLimitReached(limit: Int)
    /// The estimated model token limit was reached.
    case tokenLimitReached(limit: Int)
    /// The context-read byte limit was reached.
    case contextReadLimitReached(limit: Int)
    /// The Scheme output byte limit was reached.
    case outputLimitReached(limit: Int)
    /// The wall-time limit was reached.
    case wallTimeLimitReached(limit: Duration)
    /// A generated cell was rejected before evaluation.
    case cellRejected(String)
    /// A generated cell evaluated but raised a recoverable Scheme error.
    case cellRuntimeFailed(String)
    /// A returned evidence reference did not belong to the committed snapshot.
    case evidenceRejected(RLMEvidenceRejection)
    /// The root model client failed.
    case rootModelFailed(String)
    /// The leaf model client failed.
    case leafModelFailed(String)
    /// The cell evaluator failed or returned an inconsistent observation.
    case evaluatorFailed(String)
    /// The run was cancelled by the caller.
    case cancelled
    /// A result arrived after its run had already terminated.
    case lateResultFenced
    /// No terminal `finish` occurred within the root iteration budget.
    case noTerminalResult

    /// Whether this failure can be fed back to the root model for one repair.
    public var isRecoverableCellFailure: Bool {
        switch self {
        case .cellRejected, .cellRuntimeFailed:
            true
        default:
            false
        }
    }

    /// A bounded, single-line description safe to place in root-model history.
    public var repairDescription: String? {
        guard isRecoverableCellFailure else { return nil }
        let prefix: String
        let message: String
        switch self {
        case let .cellRejected(reason):
            prefix = "validation rejected"
            message = reason
        case let .cellRuntimeFailed(reason):
            prefix = "runtime failed"
            message = reason
        default:
            return nil
        }
        return "\(prefix): \(Self.bound(message, to: 512))"
    }

    public var description: String {
        switch self {
        case let .invalidToolArguments(message):
            return "Invalid RLM tool arguments: \(message)"
        case let .invalidPath(path):
            return "Invalid corpus path: \(path)"
        case let .absolutePathRejected(path):
            return "Absolute corpus path rejected: \(path)"
        case let .parentTraversalRejected(path):
            return "Parent traversal rejected: \(path)"
        case let .pathOutsideAllowedPrefixes(path):
            return "Path outside allowed prefixes: \(path)"
        case let .tooManyFiles(limit):
            return "Corpus file limit reached: \(limit)"
        case let .corpusTooLarge(limit):
            return "Corpus byte limit reached: \(limit)"
        case let .corpusSourceFailed(message):
            return "Corpus source failed: \(message)"
        case let .rootIterationLimitReached(limit):
            return "Root iteration limit reached: \(limit)"
        case let .leafCallLimitReached(limit):
            return "Leaf model call limit reached: \(limit)"
        case let .tokenLimitReached(limit):
            return "Estimated model token limit reached: \(limit)"
        case let .contextReadLimitReached(limit):
            return "Context read limit reached: \(limit)"
        case let .outputLimitReached(limit):
            return "Scheme output limit reached: \(limit)"
        case let .wallTimeLimitReached(limit):
            return "Wall time limit reached: \(limit)"
        case let .cellRejected(reason):
            return "Generated cell rejected: \(reason)"
        case let .cellRuntimeFailed(message):
            return "Generated cell runtime failed: \(message)"
        case let .evidenceRejected(rejection):
            return "Evidence rejected: \(rejection)"
        case let .rootModelFailed(message):
            return "Root model failed: \(message)"
        case let .leafModelFailed(message):
            return "Leaf model failed: \(message)"
        case let .evaluatorFailed(message):
            return "Cell evaluator failed: \(message)"
        case .cancelled:
            return "RLM run cancelled"
        case .lateResultFenced:
            return "RLM run fenced a late result"
        case .noTerminalResult:
            return "RLM run produced no terminal result"
        }
    }

    private static func bound(_ message: String, to maximum: Int) -> String {
        let singleLine = message
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard singleLine.count > maximum else { return singleLine }
        return String(singleLine.prefix(maximum)) + "…"
    }
}

/// Why an evidence reference was rejected against the committed snapshot.
public enum RLMEvidenceRejection: Sendable, Equatable, CustomStringConvertible {
    case tooManyReferences(limit: Int)
    case unknownChunk(String)
    case pathMismatch(chunkID: String, expected: String, actual: String)
    case invertedRange(chunkID: String, startLine: Int, endLine: Int)
    case lineRangeOutOfBounds(chunkID: String, startLine: Int, endLine: Int)

    public var description: String {
        switch self {
        case let .tooManyReferences(limit):
            return "too many references (limit \(limit))"
        case let .unknownChunk(chunkID):
            return "unknown chunk '\(chunkID)'"
        case let .pathMismatch(chunkID, expected, actual):
            return "chunk '\(chunkID)' path mismatch: expected '\(expected)', got '\(actual)'"
        case let .invertedRange(chunkID, startLine, endLine):
            return "chunk '\(chunkID)' has an inverted range \(startLine)-\(endLine)"
        case let .lineRangeOutOfBounds(chunkID, startLine, endLine):
            return "chunk '\(chunkID)' line range \(startLine)-\(endLine) is out of bounds"
        }
    }
}
