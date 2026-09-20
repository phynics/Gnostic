// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import JSONSchema
import PKContracts
import PositronicKit
@testable import GnosticCore
import Testing

@Suite("Positronic contribution seam")
@MainActor
struct PositronicContributionSeamTests {
    // MARK: - Collision validation

    @Test("a contribution cannot declare a duplicate tool identity")
    func rejectsDuplicateToolIdentity() throws {
        #expect(throws: AscendantBackendError.self) {
            _ = try PositronicContributionSurface(
                contributions: [
                    FixtureContribution(label: "first", tools: [
                        AnyTool(FixtureTool(callName: "first_name", identity: .known(id: "shared_identity"))),
                    ]),
                    FixtureContribution(label: "second", tools: [
                        AnyTool(FixtureTool(callName: "second_name", identity: .known(id: "shared_identity"))),
                    ]),
                ],
                reservedTools: [],
                recordNotice: { _, _ in }
            )
        }
    }

    @Test("a contribution cannot declare a duplicate tool call name")
    func rejectsDuplicateCallName() throws {
        #expect(throws: AscendantBackendError.self) {
            _ = try PositronicContributionSurface(
                contributions: [
                    FixtureContribution(label: "first", tools: [AnyTool(FixtureTool(callName: "shared_name"))]),
                    FixtureContribution(label: "second", tools: [AnyTool(FixtureTool(callName: "shared_name"))]),
                ],
                reservedTools: [],
                recordNotice: { _, _ in }
            )
        }
    }

    @Test("a contribution cannot override a Workspace tool call name")
    func rejectsWorkspaceToolCollision() throws {
        let workspaceTool = AnyTool(FixtureTool(callName: "workspace_echo"))
        #expect(throws: AscendantBackendError.self) {
            _ = try PositronicContributionSurface(
                contributions: [FixtureContribution(label: "fixture", tools: [AnyTool(FixtureTool(callName: "workspace_echo"))])],
                reservedTools: [workspaceTool],
                recordNotice: { _, _ in }
            )
        }
    }

    @Test("a contribution cannot override a network tool call name")
    func rejectsNetworkToolCollision() throws {
        #expect(throws: AscendantBackendError.self) {
            _ = try PositronicContributionSurface(
                contributions: [FixtureContribution(label: "fixture", tools: [AnyTool(FixtureTool(callName: "attach_workspace"))])],
                reservedTools: [AnyTool(FixtureTool(callName: "attach_workspace"))],
                recordNotice: { _, _ in }
            )
        }
    }

    @Test("a contributed tool identity cannot collide even when its call name differs")
    func rejectsReservedIdentityWithDistinctCallName() throws {
        #expect(throws: AscendantBackendError.self) {
            _ = try PositronicContributionSurface(
                contributions: [FixtureContribution(label: "fixture", tools: [
                    AnyTool(FixtureTool(callName: "novel_name", identity: .known(id: "workspace_echo"))),
                ])],
                reservedTools: [AnyTool(FixtureTool(callName: "workspace_echo"))],
                recordNotice: { _, _ in }
            )
        }
    }

    @Test("contribution labels must be static, bounded, and unique")
    func rejectsInvalidLabels() throws {
        let valid = FixtureContribution(label: "fixture.one", tools: [])
        #expect(throws: AscendantBackendError.self) {
            _ = try PositronicContributionSurface(contributions: [valid, valid], reservedTools: [], recordNotice: { _, _ in })
        }
        #expect(throws: AscendantBackendError.self) {
            _ = try PositronicContributionSurface(
                contributions: [FixtureContribution(label: "has space", tools: [])],
                reservedTools: [],
                recordNotice: { _, _ in }
            )
        }
        #expect(throws: AscendantBackendError.self) {
            _ = try PositronicContributionSurface(
                contributions: [FixtureContribution(label: "", tools: [])],
                reservedTools: [],
                recordNotice: { _, _ in }
            )
        }
        #expect(throws: AscendantBackendError.self) {
            _ = try PositronicContributionSurface(
                contributions: [FixtureContribution(label: String(repeating: "a", count: 65), tools: [])],
                reservedTools: [],
                recordNotice: { _, _ in }
            )
        }
    }

    // MARK: - Absent mode

    @Test("no contributions resolve to an inert surface")
    func emptySurfaceIsInert() throws {
        let surface = try PositronicContributionSurface(
            contributions: [],
            reservedTools: [AnyTool(FixtureTool(callName: "workspace_echo"))],
            recordNotice: { _, _ in }
        )
        #expect(surface.tools.isEmpty)
        #expect(surface.turnContextSource == nil)
    }

    // MARK: - Optional and required context failure

    @Test("an optional source failure becomes a bounded host notice and the Turn continues")
    func optionalFailureRecordsNotice() async throws {
        let recorder = NoticeRecorder()
        let secret = "super-secret-payload"
        let surface = try PositronicContributionSurface(
            contributions: [
                FixtureContribution(
                    label: "required.fixture",
                    source: FixtureContextSource(requirement: .required, text: "present-marker")
                ),
                FixtureContribution(
                    label: "optional.fixture",
                    source: FixtureContextSource(
                        requirement: .optional,
                        failure: FixtureContributionFailure(secret: secret)
                    )
                ),
            ],
            reservedTools: [],
            recordNotice: { _, message in await recorder.record(message) }
        )
        let source = try #require(surface.turnContextSource)

        let values = try await source.contributions(for: makeContextRequest())

        #expect(values.count == 1)
        #expect(values.first?.value.textValue == "present-marker")
        let notices = await recorder.messages
        #expect(notices.count == 1)
        #expect(notices.first?.contains("optional.fixture") == true)
        #expect(notices.first?.contains(secret) == false)
    }

    @Test("a required source failure aborts context resolution")
    func requiredFailureThrows() async throws {
        let surface = try PositronicContributionSurface(
            contributions: [
                FixtureContribution(
                    label: "required.fixture",
                    source: FixtureContextSource(requirement: .required, failure: FixtureContributionFailure(secret: "hidden"))
                ),
            ],
            reservedTools: [],
            recordNotice: { _, _ in }
        )
        let source = try #require(surface.turnContextSource)

        await #expect(throws: FixtureContributionFailure.self) {
            _ = try await source.contributions(for: makeContextRequest())
        }
    }

    // MARK: - Adapter integration

    @Test("a fixture context source reaches the rendered prompt with the admitted Turn identity")
    func fixtureContextReachesPrompt() async throws {
        let model = RecordingLanguageModel()
        let probe = ContributionProbe()
        let ascendantID = UUID()
        let timelineID = UUID()
        let source = FixtureContextSource(requirement: .required, text: "fixture-context-marker", probe: probe)
        let adapter = try await makeAdapter(
            ascendantID: ascendantID,
            timelineID: timelineID,
            languageModel: model,
            contributions: [FixtureContribution(label: "fixture", source: source)]
        )

        let reply = try await adapter.runTurn(
            AscendantBackendTurnRequest(timelineID: timelineID, message: "hello", clientTurnID: "turn-1"),
            updates: NoopUpdateSink()
        )

        #expect(reply == "fixture-reply")
        let promptText = await model.capturedPromptText()
        #expect(promptText.contains("fixture-context-marker"))
        let invocations = await probe.invocations
        #expect(invocations == [
            PositronicTurnInvocation(ascendantID: ascendantID, timelineID: timelineID, turnID: "turn-1"),
        ])
    }

    @Test("a required source failure aborts before provider work without damaging backend health")
    func requiredFailureAbortsBeforeProviderWork() async throws {
        let model = RecordingLanguageModel()
        let timelineID = UUID()
        let adapter = try await makeAdapter(
            ascendantID: UUID(),
            timelineID: timelineID,
            languageModel: model,
            contributions: [FixtureContribution(
                label: "required.fixture",
                source: FixtureContextSource(requirement: .required, failure: FixtureContributionFailure(secret: "hidden"))
            )]
        )

        var threw = false
        do {
            _ = try await adapter.runTurn(
                AscendantBackendTurnRequest(timelineID: timelineID, message: "hello", clientTurnID: "turn-required"),
                updates: NoopUpdateSink()
            )
        } catch {
            threw = true
        }

        #expect(threw)
        #expect(await model.invocations == 0)
        // The backend stays usable after an ordinary Turn failure.
        _ = try await adapter.operatedTimelines()
    }

    @Test("an optional source failure keeps the Turn and its providers alive")
    func optionalFailureContinues() async throws {
        let model = RecordingLanguageModel()
        let timelineID = UUID()
        let adapter = try await makeAdapter(
            ascendantID: UUID(),
            timelineID: timelineID,
            languageModel: model,
            contributions: [
                FixtureContribution(
                    label: "optional.fixture",
                    source: FixtureContextSource(
                        requirement: .optional,
                        failure: FixtureContributionFailure(secret: "hidden")
                    )
                ),
            ]
        )

        let reply = try await adapter.runTurn(
            AscendantBackendTurnRequest(timelineID: timelineID, message: "hello", clientTurnID: "turn-optional"),
            updates: NoopUpdateSink()
        )

        #expect(reply == "fixture-reply")
        #expect(await model.invocations == 1)
    }

    @Test("a contributed tool joins the Turn tool list and the enabled tool projection")
    func contributedToolJoinsTurnTools() async throws {
        let model = RecordingLanguageModel()
        let timelineID = UUID()
        let adapter = try await makeAdapter(
            ascendantID: UUID(),
            timelineID: timelineID,
            languageModel: model,
            contributions: [FixtureContribution(label: "fixture", tools: [AnyTool(FixtureTool(callName: "contributed_fixture"))])]
        )

        _ = try await adapter.runTurn(
            AscendantBackendTurnRequest(timelineID: timelineID, message: "hello", clientTurnID: "turn-tool"),
            updates: NoopUpdateSink()
        )

        #expect(await model.capturedToolNames() == ["contributed_fixture"])
        #expect(await adapter.enabledToolIDs(for: timelineID) == ["contributed_fixture"])
    }

    @Test("with no contributions the Turn exposes no contributed tool and no context section")
    func absentModeIsUnchanged() async throws {
        let model = RecordingLanguageModel()
        let timelineID = UUID()
        let adapter = try await makeAdapter(
            ascendantID: UUID(),
            timelineID: timelineID,
            languageModel: model,
            contributions: []
        )

        _ = try await adapter.runTurn(
            AscendantBackendTurnRequest(timelineID: timelineID, message: "hello", clientTurnID: "turn-absent"),
            updates: NoopUpdateSink()
        )

        #expect(await model.capturedToolNames().isEmpty)
        #expect(await adapter.enabledToolIDs(for: timelineID).isEmpty)
        #expect(await model.capturedPromptText().contains("## Turn Context") == false)
    }

    @Test("startup rejects a contribution that overrides a Workspace tool before publication")
    func startupRejectsWorkspaceCollision() async throws {
        let namespace = "contribution-workspace-collision"
        let ascendantID = UUID()
        let timelineID = UUID()
        let workspaceID = UUID()
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace),
            node: .init(id: UUID()),
            ascendants: [.init(id: ascendantID, name: "Collision", defaultTimelineID: timelineID)],
            timelines: [.init(
                id: timelineID,
                title: "Default",
                operatingAscendantID: ascendantID,
                attachments: [.local(workspaceID)]
            )],
            workspaces: [.init(id: workspaceID, name: "Echo", uri: "echo://collision", kind: "echo")]
        )
        let adapters = makeAdapters(contributions: [
            FixtureContribution(label: "fixture", tools: [AnyTool(FixtureTool(callName: "workspace_echo"))]),
        ])

        var threw = false
        do {
            let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan(), adapters: adapters)
            await runtime.shutdown()
        } catch let error as AscendantBackendError {
            threw = true
            #expect(error.reasonCode == "invalidConfiguration")
        }

        #expect(threw)
    }

    @Test("startup rejects a contribution that overrides a network tool before publication")
    func startupRejectsNetworkCollision() async throws {
        let namespace = "contribution-network-collision"
        let ascendantID = UUID()
        let timelineID = UUID()
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace),
            node: .init(id: UUID()),
            ascendants: [.init(id: ascendantID, name: "Collision", defaultTimelineID: timelineID)],
            timelines: [.init(id: timelineID, title: "Default", operatingAscendantID: ascendantID)]
        )
        let adapters = makeAdapters(contributions: [
            FixtureContribution(label: "fixture", tools: [AnyTool(FixtureTool(callName: "attach_workspace"))]),
        ])

        var threw = false
        do {
            let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan(), adapters: adapters)
            await runtime.shutdown()
        } catch let error as AscendantBackendError {
            threw = true
            #expect(error.reasonCode == "invalidConfiguration")
        }

        #expect(threw)
    }

    // MARK: - Helpers

    private func makeAdapter(
        ascendantID: UUID,
        timelineID: UUID,
        languageModel: any LLMStreamClient,
        contributions: [any PositronicContribution]
    ) async throws -> PositronicAscendantAdapter {
        let ascendant = NodeManifest.Ascendant(
            id: ascendantID,
            name: "Contribution Fixture",
            defaultTimelineID: timelineID
        )
        let timeline = NodeManifest.Timeline(
            id: timelineID,
            title: "Default",
            operatingAscendantID: ascendantID
        )
        return try await PositronicAscendantAdapter(
            ascendant: ascendant,
            backend: .init(kind: "positronic"),
            services: .empty,
            timelines: [timeline],
            languageModel: languageModel,
            contributions: contributions
        )
    }

    private func makeAdapters(contributions: [any PositronicContribution]) -> NodeRuntimeAdapters {
        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.registerBackend(
            kind: AscendantAdapterRegistry.positronicKind,
            settings: PositronicAscendantAdapter.settingsSchema
        ) { ascendant, backend, services, timelines in
            try await PositronicAscendantAdapter(
                ascendant: ascendant,
                backend: backend,
                services: services,
                timelines: timelines,
                languageModel: RecordingLanguageModel(),
                contributions: contributions
            )
        }
        return adapters
    }

    private func makeContextRequest() -> TurnContextRequest {
        TurnContextRequest(
            timelineID: UUID(),
            turnID: UUID(),
            requestID: UUID(),
            agentID: nil,
            executionKind: .agentManaged,
            message: "hello"
        )
    }
}

// MARK: - Fixtures

private struct FixtureContribution: PositronicContribution {
    let label: String
    private let toolList: [AnyTool]
    private let source: (any TurnContextSource)?

    init(label: String, tools: [AnyTool] = [], source: (any TurnContextSource)? = nil) {
        self.label = label
        toolList = tools
        self.source = source
    }

    func tools() -> [AnyTool] { toolList }
    func turnContextSource() -> (any TurnContextSource)? { source }
}

private struct FixtureTool: PKTool, Sendable {
    let callName: String
    let identityOverride: ToolReference?

    init(callName: String, identity: ToolReference? = nil) {
        self.callName = callName
        identityOverride = identity
    }

    var identity: ToolReference { identityOverride ?? .known(id: callName) }
    var name: String { callName }
    var toolDescription: String { "Fixture tool \(callName)." }
    var requiresPermission: Bool { false }
    var sideEffects: ToolSideEffects { .none }
    var parametersSchema: Schema { ToolParameterSchema.object {}.schemaDefinition }
    func canExecute() async -> Bool { true }
    func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult { .success(callName) }
}

private struct FixtureContributionFailure: Error, Equatable, Sendable {
    let secret: String
}

private struct FixtureContextSource: TurnContextSource {
    let requirement: TurnContextContributionRequirement
    var text: String?
    var failure: FixtureContributionFailure?
    var probe: ContributionProbe?

    init(
        requirement: TurnContextContributionRequirement,
        text: String? = nil,
        failure: FixtureContributionFailure? = nil,
        probe: ContributionProbe? = nil
    ) {
        self.requirement = requirement
        self.text = text
        self.failure = failure
        self.probe = probe
    }

    var failureRequirement: TurnContextContributionRequirement { requirement }

    func contributions(for _: TurnContextRequest) async throws -> [TurnContextContribution] {
        await probe?.record(PositronicTurnInvocationContext.current)
        if let failure { throw failure }
        guard let text else { return [] }
        return [try TurnContextContribution(namespace: "fixture", key: "note", text: text)]
    }
}

private actor NoticeRecorder {
    private(set) var messages: [String] = []

    func record(_ message: String) {
        messages.append(message)
    }
}

private actor ContributionProbe {
    private(set) var invocations: [PositronicTurnInvocation] = []

    func record(_ invocation: PositronicTurnInvocation?) {
        guard let invocation else { return }
        invocations.append(invocation)
    }
}

private struct NoopUpdateSink: AscendantBackendUpdateSink {
    func append(_: AscendantBackendUpdate) async throws {}
}

/// A deterministic language model that records the prompt it was asked to complete.
private final class RecordingLanguageModel: LLMStreamClient, @unchecked Sendable {
    private let capture = PromptCapture()
    private let response: String

    init(response: String = "fixture-reply") {
        self.response = response
    }

    var invocations: Int {
        get async { await capture.invocationCount }
    }

    var isConfigured: Bool {
        get async { true }
    }

    var configuration: LLMConfiguration {
        get async { .init(activeProvider: .openAI, providers: [:]) }
    }

    func capturedToolNames() async -> Set<String> {
        await capture.toolNames
    }

    func capturedPromptText() async -> String {
        await capture.promptText
    }

    func generationStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice _: LLMToolChoice?,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?,
        modelTier _: ModelTier,
        responseModalities _: Set<ResponseModality>,
        audioOutput _: AudioOutputOptions?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await capture.record(messages: messages, tools: tools ?? [])
        let response = response
        return AsyncThrowingStream { continuation in
            continuation.yield(LLMStreamChunk(
                id: "recording",
                model: "recording",
                choices: [LLMStreamChoice(
                    index: 0,
                    delta: LLMStreamDelta(content: response),
                    finishReason: "stop"
                )]
            ))
            continuation.finish()
        }
    }

    private actor PromptCapture {
        private(set) var invocationCount = 0
        private(set) var promptText = ""
        private(set) var toolNames: Set<String> = []

        func record(messages: [LLMMessage], tools: [LLMToolDefinition]) {
            invocationCount += 1
            promptText = messages.map(\.content).joined(separator: "\n")
            toolNames = Set(tools.map(\.name))
        }
    }
}
