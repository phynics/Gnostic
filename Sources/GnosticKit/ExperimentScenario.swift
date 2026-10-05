// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// One frozen scenario case.
public struct ExperimentScenarioCase: Codable, Sendable, Equatable {
    /// The case ID, for example `Q1`.
    public let id: String
    /// The prompt put to the system under test.
    public let prompt: String
    /// The reference answer a scorer compares against.
    public let reference: String
    /// The source files a correct answer should cite.
    public let evidencePaths: [String]

    /// Creates one scenario case.
    public init(id: String, prompt: String, reference: String, evidencePaths: [String]) {
        self.id = id
        self.prompt = prompt
        self.reference = reference
        self.evidencePaths = evidencePaths
    }

    /// The normalized prompt digest.
    public var promptSHA256: String { ExperimentScenarioCaseSet.hashNormalizedText(prompt) }
    /// The normalized reference-answer digest.
    public var referenceSHA256: String { ExperimentScenarioCaseSet.hashNormalizedText(reference) }
}

/// Reads a frozen case set and refuses any text that is not the approved one, so
/// a run cannot silently execute edited cases.
public enum ExperimentScenarioCaseSet {
    /// Loads a case set from `url` and refuses a digest that differs from
    /// `expectedSHA256`.
    ///
    /// - Parameters:
    ///   - url: The case-set file.
    ///   - expectedSHA256: The approved digest of the whole file.
    /// - Returns: The parsed cases and the file's digest.
    /// - Throws: ``ExperimentError/caseSetChanged(expected:actual:)`` when the
    ///   file changed, or ``ExperimentError/malformedCaseSet(_:)`` when it cannot
    ///   be parsed.
    public static func load(
        from url: URL,
        expectedSHA256: String
    ) throws -> (cases: [ExperimentScenarioCase], sha256: String) {
        let data = try Data(contentsOf: url)
        let digest = ExperimentDigest.sha256Hex([UInt8](data))
        guard digest == expectedSHA256 else {
            throw ExperimentError.caseSetChanged(expected: expectedSHA256, actual: digest)
        }
        return (try parse(String(decoding: data, as: UTF8.self)), digest)
    }

    /// Parses `## <id> — …` sections into their prompt, reference answer, and
    /// evidence paths. Paragraphs are joined and whitespace is collapsed.
    ///
    /// - Parameter text: The case-set text.
    /// - Returns: The parsed cases, in file order.
    /// - Throws: ``ExperimentError/malformedCaseSet(_:)`` when a case is missing
    ///   its prompt, reference answer, or evidence field.
    public static func parse(_ text: String) throws -> [ExperimentScenarioCase] {
        var cases: [ExperimentScenarioCase] = []
        let normalized = text.hasPrefix("## ") ? "\n" + text : text
        let sections = normalized.components(separatedBy: "\n## ").dropFirst()
        for section in sections {
            let heading = section.prefix { $0 != "\n" }
            guard let id = heading.split(whereSeparator: \.isWhitespace).first.map(String.init), !id.isEmpty else {
                continue
            }
            let question = field("Question", in: section)
            let reference = field("Reference answer", in: section)
            let evidence = field("Evidence", in: section)
            // A trailing prose section (for example "How these are used") has
            // no case fields; skip it rather than rejecting the file.
            guard question != nil || reference != nil || evidence != nil else { continue }
            guard let question, let reference, let evidence else {
                throw ExperimentError.malformedCaseSet(
                    "\(id) is missing a question, reference answer, or evidence field"
                )
            }
            cases.append(ExperimentScenarioCase(
                id: id,
                prompt: collapse(question),
                reference: collapse(reference),
                evidencePaths: codeSpans(in: evidence).filter { $0.contains("/") }
            ))
        }
        return cases
    }

    /// The Stage 0 normalization: inline-code delimiters dropped, whitespace
    /// collapsed, then SHA-256 over UTF-8.
    public static func hashNormalizedText(_ value: String) -> String {
        ExperimentDigest.sha256Hex(
            value.replacingOccurrences(of: "`", with: "")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        )
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
