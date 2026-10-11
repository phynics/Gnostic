// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// The frozen #354 scenario question set: where it lives, the digest it is pinned
/// to, and the corpus scope every scenario arm reads.
///
/// Stage 0 and the live round both load the question set through this one pin,
/// so a changed question file fails the same check in both.
public enum RLMScenarioQuestionSetPin {
    /// The repository-relative path of the frozen question set.
    public static let relativePath = "Documentation/Experiments/rlm-scenario-questions.md"
    /// The SHA-256 of the approved question set file.
    public static let sha256 = "5d57d96fd84a2afe7c9f303325cc6c8dd53138a8717a195b1a25ecaa2cc89475"
    /// The repository prefixes the scenario corpus may read.
    public static let corpusPrefixes = [
        "Sources/GnosticCore/Runtime",
        "Sources/GnosticRLM",
        "Documentation/Architecture",
    ]
}
