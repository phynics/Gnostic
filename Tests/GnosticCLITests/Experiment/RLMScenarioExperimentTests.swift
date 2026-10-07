import Foundation
import GnosticCore
import GnosticKit
import GnosticRLM
import PKContracts
import PositronicKit
import Synchronization
import Testing
import GnosticPositronicBackend
@testable import GnosticCLI
@testable import GnosticHost

@Suite("RLM scenario live experiment")
struct RLMScenarioExperimentTests {
    // MARK: - Frozen question set

    @Test("the frozen question set parses verbatim, with in-scope evidence")
    func questionSetParsesVerbatim() throws {
        let (questions, digest) = try RLMScenarioQuestionSet.load(repositoryRoot: Self.repositoryRoot)
        #expect(digest == RLMScenarioQuestionSet.pinnedSHA256)
        #expect(questions.map(\.id) == (1...12).map { "Q\($0)" })

        // Runs must use the approved file's text. The Stage 0 harness carries
        // its own copy, which differs for Q7, Q8, Q9, Q11, and Q12.
        let first = try #require(questions.first)
        #expect(first.prompt == "What is Gnostic's host boundary, and which PositronicKit values may cross it?")
        let last = try #require(questions.last)
        #expect(last.prompt == "How is a backend failure contained, and how is backend retirement bounded?")
        #expect(last.reference.hasPrefix("An ordinary Turn failure leaves the backend healthy and usable;"))
        #expect(last.reference.contains("recorded as an exceeded deadline rather than blocking"))
        #expect(!last.reference.contains("**"))

        for question in questions {
            #expect(!question.reference.isEmpty)
            #expect(!question.evidencePaths.isEmpty, "\(question.id) lists no evidence files")
            for path in question.evidencePaths {
                #expect(
                    RLMScenarioQuestionSet.corpusPrefixes.contains { path.hasPrefix($0) },
                    "\(question.id) evidence \(path) is outside the corpus scope"
                )
                #expect(
                    FileManager.default.fileExists(atPath: Self.repositoryRoot.appendingPathComponent(path).path),
                    "\(question.id) evidence \(path) does not exist"
                )
            }
        }
    }

    @Test("an edited question set is refused before any run")
    func editedQuestionSetIsRefused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = root.appendingPathComponent(RLMScenarioQuestionSet.relativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var text = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent(RLMScenarioQuestionSet.relativePath),
            encoding: .utf8
        )
        text += "\n"
        try text.write(to: target, atomically: true, encoding: .utf8)

        #expect {
            _ = try RLMScenarioQuestionSet.load(repositoryRoot: root)
        } throws: { error in
            guard case .questionSetChanged? = error as? RLMScenarioError else { return false }
            return true
        }
    }

    // MARK: - Metering

    @Test("the stream transport keeps the provider-reported usage")
    func streamTransportKeepsUsage() async throws {
        let transport = LLMStreamClientExperimentTransport(client: UsageReportingClient(usage: LLMTokenUsage(promptTokens: 120, completionTokens: 30)))
        let generation = try await transport.generate(prompt: "p", tier: .fast)
        #expect(generation == ExperimentGeneration(text: "(finish \"a\" '())", promptTokens: 120, completionTokens: 30))
    }

    // MARK: - Plan, scoring, and projection

    @Test("the worst-case ceiling follows the run budget")
    func ceilingFollowsBudget() {
        let plan = Self.plan(stage: .pilot)
        #expect(plan.runKeys.count == 6)
        #expect(plan.runKeys.prefix(2).map(\.arm) == ["guile", "chibi"])
        let ceiling = plan.ceiling
        #expect(ceiling.maximumModelCalls == 6 * (8 + 32))
        #expect(ceiling.maximumEstimatedTokens == 6 * 200_000)
        #expect(abs((ceiling.maximumEstimatedCostUSD ?? 0) - 6 * 200_000 * 15 / 1_000_000) < 1e-9)
    }

    @Test("the rating sheet hides the arm and scores round-trip onto runs")
    func ratingSheetIsBlindAndScoresApply() async throws {
        let artifact = try await Self.runner(stage: .pilot, maxCost: 100, runCost: 0.5).run(resuming: nil)
        let sheet = ExperimentBlindRating.sheet(for: artifact, cases: Self.questions)
        #expect(sheet.items.count == 6)
        #expect(Set(sheet.items.map(\.id)).count == 6)
        let encoded = String(decoding: try JSONEncoder().encode(sheet), as: UTF8.self)
        #expect(!encoded.contains("guile") && !encoded.contains("chibi"))

        let scored = try ExperimentBlindRating.apply([sheet.items[0].id: 7], to: artifact)
        #expect(scored.runs.compactMap(\.score) == [7])
        #expect(throws: ExperimentError.self) {
            _ = try ExperimentBlindRating.apply([sheet.items[0].id: 11], to: artifact)
        }
        #expect(throws: ExperimentError.self) {
            _ = try ExperimentBlindRating.apply(["unknown": 5], to: artifact)
        }
    }

    @Test("an unpriced subscription round meters tokens without a dollar ceiling")
    func unpricedRoundHasNoDollarCeiling() async throws {
        let plan = ExperimentPlan(manifest: Self.manifest(stage: .pilot, pricing: nil), matrixCaseCount: 12, pilot: nil)
        #expect(plan.ceiling.maximumEstimatedCostUSD == nil)
        let artifact = try await ExperimentRunner(
            plan: plan,
            maximumCostUSD: nil,
            scoringRule: ExperimentBlindRating.rule,
            execute: { key in Self.record(key, cost: 0) },
            persist: { _ in },
            report: { _ in }
        ).run(resuming: nil)
        #expect(artifact.status == "complete")
        #expect(artifact.runs.count == 6)
        #expect(artifact.runs.allSatisfy { $0.totalUsage.promptTokens == 150 })
    }

    @Test("a light round plans one repetition over the chosen questions")
    func lightRoundPlansFewerRuns() {
        let manifest = Self.manifest(stage: .matrix, repetitions: 1, caseIDs: ["Q2", "Q7"], pricing: nil)
        let plan = ExperimentPlan(manifest: manifest, matrixCaseCount: 12, pilot: nil)
        #expect(plan.runKeys.count == 4)
        // A three-repetition pilot still authorises a one-repetition matrix.
        #expect(manifest.sharesComparison(with: Self.manifest(stage: .pilot, pricing: nil)).isEmpty)
    }

    // MARK: - Runner

    @Test("a complete pilot records every run and projects the full matrix")
    func pilotCompletesWithProjection() async throws {
        let persisted = Recorder<ExperimentRunArtifact>()
        let artifact = try await Self.runner(stage: .pilot, maxCost: 100, runCost: 0.5, persisted: persisted).run(resuming: nil)

        #expect(artifact.status == "complete")
        #expect(artifact.runs.count == 6)
        #expect(abs(artifact.costActualUSD - 3) < 1e-9)
        #expect(persisted.values.count == 7)
        let projection = try #require(artifact.costProjection)
        // The fixture round uses three repetitions; the projection follows it.
        #expect(projection.projectedRuns == 12 * 3 * 2)
        #expect(abs(projection.projectedCostUSD - 72 * 0.5) < 1e-9)
        #expect(projection.arms.map(\.arm) == ["chibi", "guile"])
    }

    @Test("resuming runs only the missing runs")
    func resumeRunsOnlyMissing() async throws {
        let calls = Recorder<ExperimentRunKey>()
        let first = try await Self.runner(stage: .pilot, maxCost: 1.2, runCost: 0.5).run(resuming: nil)
        #expect(first.status == "stopped-at-cost-ceiling")
        #expect(first.runs.count == 2)

        let resumed = try await Self.runner(stage: .pilot, maxCost: 100, runCost: 0.5, calls: calls).run(resuming: first)
        #expect(resumed.status == "complete")
        #expect(resumed.runs.count == 6)
        #expect(calls.values.count == 4)
        #expect(Set(resumed.runs.map(\.key)).count == 6)
    }

    @Test("an artifact from a different round is never resumed")
    func differentRoundIsRefused() async throws {
        let existing = try await Self.runner(stage: .pilot, maxCost: 100, runCost: 0.5, rootModel: "other-model").run(resuming: nil)
        await #expect(throws: ExperimentError.manifestMismatch("differs in regime")) {
            _ = try await Self.runner(stage: .pilot, maxCost: 100, runCost: 0.5).run(resuming: existing)
        }
    }

    @Test("the matrix needs a complete pilot that ran the same comparison")
    func matrixNeedsMatchingPilot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pilotURL = directory.appendingPathComponent("pilot.json")
        let matrix = Self.manifest(stage: .matrix)

        #expect(throws: ExperimentError.self) {
            _ = try ExperimentArtifactFile.authorisingPilot(at: pilotURL, displayPath: "pilot.json", for: matrix)
        }

        let stopped = try await Self.runner(stage: .pilot, maxCost: 0.6, runCost: 0.5).run(resuming: nil)
        try ExperimentArtifactFile.write(stopped, to: pilotURL)
        #expect(throws: ExperimentError.self) {
            _ = try ExperimentArtifactFile.authorisingPilot(at: pilotURL, displayPath: "pilot.json", for: matrix)
        }

        let complete = try await Self.runner(stage: .pilot, maxCost: 100, runCost: 0.5).run(resuming: nil)
        try ExperimentArtifactFile.write(complete, to: pilotURL)
        #expect(throws: ExperimentError.self) {
            _ = try ExperimentArtifactFile.authorisingPilot(
                at: pilotURL,
                displayPath: "pilot.json",
                for: Self.manifest(stage: .matrix, rootModel: "other-model")
            )
        }
        let reference = try ExperimentArtifactFile.authorisingPilot(at: pilotURL, displayPath: "pilot.json", for: matrix)
        #expect(reference.path == "pilot.json")
        #expect(reference.projection == complete.costProjection)
    }

    // MARK: - Fixtures

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let questions = (1...12).map {
        ExperimentScenarioCase(id: "Q\($0)", prompt: "question \($0)", reference: "answer", evidencePaths: ["A.md"])
    }

    private static func manifest(
        stage: RLMScenarioStage,
        rootModel: String = "root-model",
        repetitions: Int = 3,
        caseIDs: [String]? = nil,
        pricing: ExperimentPricing? = ExperimentPricing(inputUSDPerMillionTokens: 3, outputUSDPerMillionTokens: 15, ratesDate: "2026-09-25")
    ) -> ExperimentRunManifest {
        ExperimentRunManifest(
            manifestID: "rlm-scenario-manifest-v1",
            manifestVersion: "v7",
            segment: stage.rawValue,
            regime: ExperimentRegime(
                backendKind: "positronic",
                modules: ["rlm"],
                modelTiers: ["primary": rootModel, "utility": "utility", "fast": "fast"],
                provider: "Anthropic",
                endpoint: "https://example.invalid",
                policies: ["scenario": "rlm-scenario"]
            ),
            gitCommit: "commit",
            workingTreeClean: true,
            imageDigest: "sha256:image",
            host: "linux/x86_64",
            samplingParameters: "defaults",
            budget: RLMScenarioPreparation.budgetDescription(.standard),
            caseSetSHA256: "questions",
            corpusRevisionDigest: "corpus",
            caseIDs: caseIDs ?? (stage == .pilot ? ["Q1"] : questions.map(\.id)),
            arms: ["guile", "chibi"],
            repetitions: repetitions,
            pricing: pricing
        )
    }

    private static func plan(stage: RLMScenarioStage, rootModel: String = "root-model") -> ExperimentPlan {
        // A pilot plan holds only its selected question, as the command builds it.
        ExperimentPlan(manifest: manifest(stage: stage, rootModel: rootModel), matrixCaseCount: questions.count, pilot: nil)
    }

    private static func runner(
        stage: RLMScenarioStage,
        maxCost: Double,
        runCost: Double,
        rootModel: String = "root-model",
        persisted: Recorder<ExperimentRunArtifact> = Recorder(),
        calls: Recorder<ExperimentRunKey> = Recorder()
    ) -> ExperimentRunner {
        ExperimentRunner(
            plan: plan(stage: stage, rootModel: rootModel),
            maximumCostUSD: maxCost,
            scoringRule: ExperimentBlindRating.rule,
            execute: { key in
                calls.append(key)
                return record(key, cost: runCost)
            },
            persist: { persisted.append($0) },
            report: { _ in }
        )
    }

    private static func record(_ key: ExperimentRunKey, cost: Double) -> ExperimentRunRecord {
        ExperimentRunRecord(
            caseID: key.caseID,
            arm: key.arm,
            repetition: key.repetition,
            startedAtUTC: "2026-09-25T00:00:00Z",
            outcome: "completed",
            failure: nil,
            answer: "answer",
            evidence: [],
            sourceRevisionDigest: "corpus",
            wallMilliseconds: 10,
            metrics: ExperimentRunMetrics(values: [
                "rootIterations": 1,
                "leafModelCalls": 1,
            ]),
            rootUsage: ExperimentUsage(calls: 2, promptTokens: 100, completionTokens: 10),
            leafUsage: ExperimentUsage(calls: 1, promptTokens: 50, completionTokens: 5),
            costUSD: cost,
            costComplete: true,
            score: nil
        )
    }
}

private final class Recorder<Value: Sendable>: Sendable {
    private let storage = Mutex<[Value]>([])

    var values: [Value] { storage.withLock { $0 } }

    func append(_ value: Value) {
        storage.withLock { $0.append(value) }
    }
}

private final class UsageReportingClient: LLMStreamClient, @unchecked Sendable {
    let usage: LLMTokenUsage

    init(usage: LLMTokenUsage) {
        self.usage = usage
    }

    var isConfigured: Bool { get async { true } }
    var configuration: LLMConfiguration { get async { .init(activeProvider: .openAI, providers: [:]) } }

    func chatStream(
        messages _: [LLMMessage],
        tools _: [LLMToolDefinition]?,
        toolChoice _: LLMToolChoice?,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?,
        modelTier _: ModelTier
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let usage = usage
        return AsyncThrowingStream { continuation in
            for piece in ["(finish ", "\"a\" '())"] {
                continuation.yield(LLMStreamChunk(
                    id: "usage",
                    model: "stub",
                    choices: [LLMStreamChoice(index: 0, delta: LLMStreamDelta(content: piece))]
                ))
            }
            continuation.yield(LLMStreamChunk(id: "usage", model: "stub", choices: [], usage: usage))
            continuation.finish()
        }
    }

    func generationStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        modelTier: ModelTier,
        responseModalities _: Set<ResponseModality>,
        audioOutput _: AudioOutputOptions?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await chatStream(messages: messages, tools: tools, toolChoice: toolChoice, responseFormat: responseFormat, generationParameters: generationParameters, modelTier: modelTier)
    }

    func loadConfiguration() async {}
    func updateConfiguration(_: LLMConfiguration) async throws {}
    func clearConfiguration() async {}
    func restoreFromBackup() async throws {}
    func exportConfiguration() async throws -> Data { Data() }
    func importConfiguration(from _: Data) async throws {}
    func sendMessage(_ content: String) async throws -> String { content }
    func sendMessage(
        _: String,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?,
        useUtilityModel _: Bool
    ) async throws -> String { "ok" }
    func generateTags(for _: String) async throws -> [String] { [] }
    func generateTitle(for _: [Message]) async throws -> String { "stub" }
    func fetchAvailableModels() async throws -> [String]? { nil }
}
