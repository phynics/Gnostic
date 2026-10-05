// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticKit

/// The RLM scenario consumes the experiment kit's frozen case model
/// (GNO-PLAT-031). GNO-PLAT-038 retargets the scenario onto the kit types
/// directly and deletes this wrapper.
typealias RLMScenarioQuestion = ExperimentScenarioCase

/// Reads the frozen #354 question set and refuses any text that is not the
/// approved one, so a live round cannot silently run edited questions.
enum RLMScenarioQuestionSet {
    static let relativePath = "Documentation/Experiments/rlm-scenario-questions.md"
    /// The SHA-256 of the approved file, as recorded by the Stage 0 artifact.
    static let pinnedSHA256 = "5d57d96fd84a2afe7c9f303325cc6c8dd53138a8717a195b1a25ecaa2cc89475"
    static let corpusPrefixes = [
        "Sources/GnosticCore/Runtime",
        "Sources/GnosticRLM",
        "Documentation/Architecture",
    ]

    static func load(repositoryRoot: URL) throws -> (questions: [RLMScenarioQuestion], sha256: String) {
        do {
            let (cases, sha256) = try ExperimentScenarioCaseSet.load(
                from: repositoryRoot.appendingPathComponent(relativePath),
                expectedSHA256: pinnedSHA256
            )
            guard cases.map(\.id) == (1...12).map({ "Q\($0)" }) else {
                throw RLMScenarioError.malformedQuestionSet("expected Q1 through Q12, found \(cases.map(\.id))")
            }
            return (cases, sha256)
        } catch let error as ExperimentError {
            switch error {
            case let .caseSetChanged(expected, actual):
                throw RLMScenarioError.questionSetChanged(expected: expected, actual: actual)
            case let .malformedCaseSet(reason):
                throw RLMScenarioError.malformedQuestionSet(reason)
            default:
                throw RLMScenarioError.malformedQuestionSet(error.description)
            }
        }
    }
}

/// Structured failures for the scenario experiment command.
enum RLMScenarioError: Error, Equatable, CustomStringConvertible {
    case questionSetChanged(expected: String, actual: String)
    case malformedQuestionSet(String)
    case invalidArguments(String)
    case configuration(String)
    case roundMismatch(String)
    case pilotRequired(String)

    var description: String {
        switch self {
        case let .questionSetChanged(expected, actual):
            "the frozen question set changed (expected SHA-256 \(expected), found \(actual)); a new question set needs a new manifest version"
        case let .malformedQuestionSet(reason):
            "the frozen question set could not be parsed: \(reason)"
        case let .invalidArguments(reason):
            reason
        case let .configuration(reason):
            reason
        case let .roundMismatch(reason):
            "the existing artifact belongs to a different round and cannot be resumed (manifest §7 void-round rule): \(reason)"
        case let .pilotRequired(reason):
            "the full matrix needs an accepted Stage 2 pilot (manifest §8): \(reason)"
        }
    }
}
