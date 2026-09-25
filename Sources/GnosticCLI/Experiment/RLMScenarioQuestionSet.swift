// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticRLM

/// One frozen scenario question, parsed from `rlm-scenario-questions.md`.
struct RLMScenarioQuestion: Sendable, Equatable {
    let id: String
    let question: String
    let referenceAnswer: String
    /// Repository files a correct answer should cite (manifest §5 sufficiency).
    let evidencePaths: [String]

    var questionSHA256: String { RLMScenarioQuestionSet.hashNormalizedText(question) }
    var referenceAnswerSHA256: String { RLMScenarioQuestionSet.hashNormalizedText(referenceAnswer) }
}

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
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(relativePath))
        let digest = RLMDigest.sha256Hex([UInt8](data))
        guard digest == pinnedSHA256 else {
            throw RLMScenarioError.questionSetChanged(expected: pinnedSHA256, actual: digest)
        }
        return (try parse(String(decoding: data, as: UTF8.self)), digest)
    }

    /// Parses `## Qn — …` sections into their question, reference answer, and
    /// evidence paths. Paragraphs are joined and whitespace is collapsed.
    static func parse(_ text: String) throws -> [RLMScenarioQuestion] {
        var questions: [RLMScenarioQuestion] = []
        let sections = text.components(separatedBy: "\n## Q").dropFirst()
        for section in sections {
            guard let idEnd = section.firstIndex(where: { !$0.isNumber }) else { continue }
            let id = "Q" + section[..<idEnd]
            guard let question = field("Question", in: section),
                  let answer = field("Reference answer", in: section),
                  let evidence = field("Evidence", in: section) else {
                throw RLMScenarioError.malformedQuestionSet("\(id) is missing a question, reference answer, or evidence field")
            }
            questions.append(RLMScenarioQuestion(
                id: id,
                question: collapse(question),
                referenceAnswer: collapse(answer),
                evidencePaths: codeSpans(in: evidence).filter { $0.contains("/") }
            ))
        }
        guard questions.map(\.id) == (1...12).map({ "Q\($0)" }) else {
            throw RLMScenarioError.malformedQuestionSet("expected Q1 through Q12, found \(questions.map(\.id))")
        }
        return questions
    }

    /// The Stage 0 normalization: inline-code delimiters dropped, whitespace
    /// collapsed, then SHA-256 over UTF-8.
    static func hashNormalizedText(_ value: String) -> String {
        RLMDigest.sha256Hex(value.replacingOccurrences(of: "`", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }

    private static func field(_ name: String, in section: String) -> String? {
        guard let start = section.range(of: "**\(name).**") else { return nil }
        let rest = section[start.upperBound...]
        let end = rest.range(of: "\n\n")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    private static func collapse(_ value: String) -> String {
        value.replacingOccurrences(of: "`", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func codeSpans(in value: String) -> [String] {
        value.split(separator: "`", omittingEmptySubsequences: false)
            .enumerated()
            .filter { $0.offset % 2 == 1 }
            .map { String($0.element) }
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
