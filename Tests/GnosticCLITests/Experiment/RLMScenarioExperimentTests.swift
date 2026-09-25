import Foundation
import GnosticCore
import GnosticRLM
import PKContracts
import PositronicKit
import Synchronization
import Testing
@testable import GnosticCLI

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
        #expect(first.question == "What is Gnostic's host boundary, and which PositronicKit values may cross it?")
        let last = try #require(questions.last)
        #expect(last.question == "How is a backend failure contained, and how is backend retirement bounded?")
        #expect(last.referenceAnswer.hasPrefix("An ordinary Turn failure leaves the backend healthy and usable;"))
        #expect(last.referenceAnswer.contains("recorded as an exceeded deadline rather than blocking"))
        #expect(!last.referenceAnswer.contains("**"))

        for question in questions {
            #expect(!question.referenceAnswer.isEmpty)
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
        let transport = RLMScenarioStreamTransport(client: UsageReportingClient(usage: LLMTokenUsage(promptTokens: 120, completionTokens: 30)))
        let generation = try await transport.generate(prompt: "p", tier: .fast)
        #expect(generation == RLMScenarioGeneration(text: "(finish \"a\" '())", promptTokens: 120, completionTokens: 30))
    }

    @Test("metering counts calls and marks calls whose provider reported no usage")
    func meteringCountsUsage() async throws {
        let model = RLMScenarioMeteredModel(transport: FixedTransport(responses: [
            RLMScenarioGeneration(text: "one", promptTokens: 100, completionTokens: 10),
            RLMScenarioGeneration(text: "two", promptTokens: nil, completionTokens: nil),
            RLMScenarioGeneration(text: "  ", promptTokens: 5, completionTokens: 0),
        ]))
        _ = try await model.generate(prompt: "a", tier: .primary)
        _ = try await model.generate(prompt: "b", tier: .fast)
        await #expect(throws: RLMFailure.self) {
            _ = try await model.generate(prompt: "c", tier: .fast)
        }

        let usage = await model.usage
        #expect(usage == RLMScenarioUsage(calls: 3, promptTokens: 105, completionTokens: 10, callsWithoutUsage: 1))
        let pricing = RLMScenarioPricing(inputUSDPerMillionTokens: 3, outputUSDPerMillionTokens: 15, ratesDate: "2026-09-25")
        #expect(abs(pricing.cost(of: usage) - (105 * 3 + 10 * 15) / 1_000_000) < 1e-12)
    }

    // MARK: - Plan, scoring, and projection

    @Test("the worst-case ceiling follows the run budget")
    func ceilingFollowsBudget() {
        let plan = Self.plan(stage: .pilot)
        #expect(plan.runKeys.count == 6)
        #expect(plan.runKeys.prefix(2).map(\.executor) == ["guile", "chibi"])
        let ceiling = plan.ceiling
        #expect(ceiling.maximumModelCalls == 6 * (8 + 32))
        #expect(ceiling.maximumEstimatedTokens == 6 * 200_000)
        #expect(abs((ceiling.maximumEstimatedCostUSD ?? 0) - 6 * 200_000 * 15 / 1_000_000) < 1e-9)
    }

    @Test("mechanical evidence scores follow the proposed mapping")
    func mechanicalScores() {
        let expected = ["A.md", "B.md"]
        let evidence = { (paths: [String]) in
            paths.map { RLMScenarioEvidence(chunkID: "c", path: $0, startLine: 1, endLine: 2) }
        }
        #expect(RLMScenarioMechanicalScore.score(evidence: evidence(["A.md", "B.md"]), expectedPaths: expected).evidenceSufficiency == 2)
        #expect(RLMScenarioMechanicalScore.score(evidence: evidence(["B.md", "C.md"]), expectedPaths: expected).evidenceSufficiency == 1)
        let none = RLMScenarioMechanicalScore.score(evidence: [], expectedPaths: expected)
        #expect(none.evidenceSufficiency == 0)
        #expect(none.evidenceCorrectness == 0)
        #expect(RLMScenarioMechanicalScore.score(evidence: evidence(["C.md"]), expectedPaths: expected).evidenceCorrectness == 3)
    }

    @Test("an unpriced subscription round meters tokens without a dollar ceiling")
    func unpricedRoundHasNoDollarCeiling() async throws {
        let plan = RLMScenarioPlan(identity: Self.identity(stage: .pilot, pricing: nil), questions: Array(Self.questions.prefix(1)), matrixQuestionCount: 12, pilot: nil)
        #expect(plan.ceiling.maximumEstimatedCostUSD == nil)
        let artifact = try await RLMScenarioLiveRunner(
            plan: plan,
            maximumCostUSD: nil,
            execute: { _, key in Self.record(key, cost: 0) },
            persist: { _ in },
            report: { _ in }
        ).run(resuming: nil)
        #expect(artifact.status == "complete")
        #expect(artifact.runs.count == 6)
        #expect(artifact.runs.allSatisfy { $0.totalUsage.promptTokens == 150 })
    }

    @Test("a light round plans one repetition over the chosen questions")
    func lightRoundPlansFewerRuns() {
        var identity = Self.identity(stage: .matrix, repetitions: 1)
        identity = RLMScenarioRoundIdentity(
            manifestID: identity.manifestID, manifestVersion: identity.manifestVersion, stage: .matrix,
            gitCommit: identity.gitCommit, workingTreeClean: true, imageDigest: identity.imageDigest,
            host: identity.host, provider: identity.provider, endpoint: identity.endpoint,
            rootModel: identity.rootModel, leafModels: identity.leafModels,
            samplingParameters: identity.samplingParameters, budget: identity.budget,
            questionSetSHA256: identity.questionSetSHA256, corpusRevisionDigest: identity.corpusRevisionDigest,
            questionIDs: ["Q2", "Q7"], executors: identity.executors, repetitions: 1, pricing: nil
        )
        let plan = RLMScenarioPlan(identity: identity, questions: Self.questions, matrixQuestionCount: 12, pilot: nil)
        #expect(plan.runKeys.count == 4)
        // A three-repetition pilot still authorises a one-repetition matrix.
        #expect(identity.sharesComparison(with: Self.identity(stage: .pilot, pricing: nil)).isEmpty)
    }

    // MARK: - Runner

    @Test("a complete pilot records every run and projects the full matrix")
    func pilotCompletesWithProjection() async throws {
        let persisted = Recorder<RLMScenarioLiveArtifact>()
        let artifact = try await Self.runner(stage: .pilot, maxCost: 100, runCost: 0.5, persisted: persisted).run(resuming: nil)

        #expect(artifact.status == "complete")
        #expect(artifact.runs.count == 6)
        #expect(abs(artifact.costActualUSD - 3) < 1e-9)
        #expect(persisted.values.count == 7)
        let projection = try #require(artifact.costProjection)
        // The fixture round uses three repetitions; the projection follows it.
        #expect(projection.projectedRuns == 12 * 3 * 2)
        #expect(abs(projection.projectedCostUSD - 72 * 0.5) < 1e-9)
        #expect(projection.executors.map(\.executor) == ["chibi", "guile"])
    }

    @Test("resuming runs only the missing runs")
    func resumeRunsOnlyMissing() async throws {
        let calls = Recorder<RLMScenarioRunKey>()
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
        var existing = try await Self.runner(stage: .pilot, maxCost: 100, runCost: 0.5).run(resuming: nil)
        existing = RLMScenarioLiveArtifact(
            schemaVersion: existing.schemaVersion,
            round: Self.identity(stage: .pilot, rootModel: "other-model"),
            status: existing.status,
            updatedAtUTC: existing.updatedAtUTC,
            ceiling: existing.ceiling,
            authorisedMaximumCostUSD: existing.authorisedMaximumCostUSD,
            pilot: nil,
            mechanicalScoringRule: existing.mechanicalScoringRule,
            measurements: existing.measurements,
            runs: existing.runs,
            costActualUSD: existing.costActualUSD,
            costComplete: existing.costComplete,
            costProjection: nil
        )
        await #expect(throws: RLMScenarioError.roundMismatch("differs in rootModel, leafModels")) {
            _ = try await Self.runner(stage: .pilot, maxCost: 100, runCost: 0.5).run(resuming: existing)
        }
    }

    @Test("the matrix needs a complete pilot that ran the same comparison")
    func matrixNeedsMatchingPilot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pilotURL = directory.appendingPathComponent("pilot.json")
        let matrix = Self.identity(stage: .matrix)

        #expect(throws: RLMScenarioError.self) {
            _ = try RLMScenarioArtifactFile.authorisingPilot(at: pilotURL, displayPath: "pilot.json", for: matrix)
        }

        let stopped = try await Self.runner(stage: .pilot, maxCost: 0.6, runCost: 0.5).run(resuming: nil)
        try RLMScenarioArtifactFile.write(stopped, to: pilotURL)
        #expect(throws: RLMScenarioError.self) {
            _ = try RLMScenarioArtifactFile.authorisingPilot(at: pilotURL, displayPath: "pilot.json", for: matrix)
        }

        let complete = try await Self.runner(stage: .pilot, maxCost: 100, runCost: 0.5).run(resuming: nil)
        try RLMScenarioArtifactFile.write(complete, to: pilotURL)
        #expect(throws: RLMScenarioError.self) {
            _ = try RLMScenarioArtifactFile.authorisingPilot(
                at: pilotURL,
                displayPath: "pilot.json",
                for: Self.identity(stage: .matrix, rootModel: "other-model")
            )
        }
        let reference = try RLMScenarioArtifactFile.authorisingPilot(at: pilotURL, displayPath: "pilot.json", for: matrix)
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
        RLMScenarioQuestion(id: "Q\($0)", question: "question \($0)", referenceAnswer: "answer", evidencePaths: ["A.md"])
    }

    private static func identity(
        stage: RLMScenarioStage,
        rootModel: String = "root-model",
        repetitions: Int = 3,
        pricing: RLMScenarioPricing? = RLMScenarioPricing(inputUSDPerMillionTokens: 3, outputUSDPerMillionTokens: 15, ratesDate: "2026-09-25")
    ) -> RLMScenarioRoundIdentity {
        RLMScenarioRoundIdentity(
            manifestID: "rlm-scenario-manifest-v1",
            manifestVersion: "v7",
            stage: stage,
            gitCommit: "commit",
            workingTreeClean: true,
            imageDigest: "sha256:image",
            host: "linux/x86_64",
            provider: "Anthropic",
            endpoint: "https://example.invalid",
            rootModel: rootModel,
            leafModels: RLMScenarioLeafModels(primary: rootModel, utility: "utility", fast: "fast"),
            samplingParameters: "defaults",
            budget: RLMScenarioBudgetDescription(.standard),
            questionSetSHA256: "questions",
            corpusRevisionDigest: "corpus",
            questionIDs: stage == .pilot ? ["Q1"] : questions.map(\.id),
            executors: ["guile", "chibi"],
            repetitions: repetitions,
            pricing: pricing
        )
    }

    private static func plan(stage: RLMScenarioStage) -> RLMScenarioPlan {
        // A pilot plan holds only its selected question, as the command builds it.
        let selected = stage == .pilot ? Array(questions.prefix(1)) : questions
        return RLMScenarioPlan(identity: identity(stage: stage), questions: selected, matrixQuestionCount: questions.count, pilot: nil)
    }

    private static func runner(
        stage: RLMScenarioStage,
        maxCost: Double,
        runCost: Double,
        persisted: Recorder<RLMScenarioLiveArtifact> = Recorder(),
        calls: Recorder<RLMScenarioRunKey> = Recorder()
    ) -> RLMScenarioLiveRunner {
        RLMScenarioLiveRunner(
            plan: plan(stage: stage),
            maximumCostUSD: maxCost,
            execute: { _, key in
                calls.append(key)
                return record(key, cost: runCost)
            },
            persist: { persisted.append($0) },
            report: { _ in }
        )
    }

    private static func record(_ key: RLMScenarioRunKey, cost: Double) -> RLMScenarioRunRecord {
        RLMScenarioRunRecord(
            questionID: key.questionID,
            executor: key.executor,
            repetition: key.repetition,
            startedAtUTC: "2026-09-25T00:00:00Z",
            outcome: "completed",
            failure: nil,
            answer: "answer",
            evidence: [],
            snapshotRevisionDigest: "corpus",
            wallMilliseconds: 10,
            metrics: RLMScenarioRunMetrics(RLMRunMetrics(snapshotID: "s")),
            rootUsage: RLMScenarioUsage(calls: 2, promptTokens: 100, completionTokens: 10),
            leafUsage: RLMScenarioUsage(calls: 1, promptTokens: 50, completionTokens: 5),
            costUSD: cost,
            costComplete: true,
            mechanicalScore: nil
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

private actor FixedTransport: RLMScenarioModelTransport {
    private var responses: [RLMScenarioGeneration]

    init(responses: [RLMScenarioGeneration]) {
        self.responses = responses
    }

    func generate(prompt _: String, tier _: PositronicContributionModelTier) async throws -> RLMScenarioGeneration {
        responses.removeFirst()
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
