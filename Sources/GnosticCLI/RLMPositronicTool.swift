// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticRLM
import JSONSchema
import JSONSchemaBuilder
import PKContracts
import PositronicKit

private struct PositronicWorkspaceCorpusSource: RLMCorpusSource {
    let workspaceID: UUID
    let reader: any PositronicContributionWorkspaceReader

    func listFiles() async throws -> [RLMCorpusSourceFile] {
        try await reader.listFiles(workspaceID: workspaceID, path: "")
            .map { RLMCorpusSourceFile(path: $0, byteCount: 0) }
    }

    func readFile(at path: String) async throws -> RLMCorpusFileContent {
        let content = try await reader.readFile(workspaceID: workspaceID, path: path)
        return RLMCorpusFileContent(path: path, bytes: Array(content.utf8))
    }
}

private struct RLMProgressReporter: RLMProgressSink {
    let sink: @Sendable (String) async -> Void

    func report(_ message: String) async {
        await sink(message)
    }
}

private struct RLMAnalysisOutput: Codable, Sendable {
    let answer: String
    let evidence: [RLMEvidenceOutput]
    let metrics: RLMAnalysisMetricsOutput
    let snapshotID: String
}

private struct RLMEvidenceOutput: Codable, Sendable {
    let chunkID: String
    let path: String
    let startLine: Int
    let endLine: Int
}

private struct RLMAnalysisMetricsOutput: Codable, Sendable {
    let rootIterations: Int
    let leafModelCalls: Int
    let corpusFiles: Int
    let corpusChunks: Int
    let corpusBytes: Int
    let contextReadBytes: Int
    let estimatedModelTokens: Int
    let evidenceReferences: Int
}

/// The optional bounded recursive analysis tool.
struct AnalyzeWorkspaceCorpusTool: PKTool, Sendable {
    let runtime: PositronicContributionRuntimeContext
    let worker: RLMWorkerSelection

    let callName = "analyze_workspace_corpus"
    let name = "Analyze workspace corpus"
    let toolDescription = "Runs bounded recursive analysis over one attached local text Workspace and returns an answer with validated evidence."
    let requiresPermission = true
    let sideEffects: ToolSideEffects = .externalProcess

    var parametersSchema: Schema {
        ToolParameterSchema.object {
            JSONProperty(key: "question") {
                JSONString().description("A non-empty question to answer from the Workspace corpus.")
            }.required()
            JSONProperty(key: "workspaceID") {
                JSONString().description("UUID of one attached local file-capable Workspace.")
            }.required()
            JSONProperty(key: "pathPrefixes") {
                JSONArray {
                    JSONString().description("A relative path prefix inside the Workspace.")
                }.description("Optional bounded relative path prefixes.")
            }
        }.schemaDefinition
    }

    func canExecute() async -> Bool {
        runtime.workspaceReader != nil && runtime.modelService != nil && !runtime.allowedWorkspaceIDs.isEmpty
    }

    func execute(parameters: [String: AnyCodable]) async throws -> ToolResult {
        guard PositronicTurnInvocationContext.current != nil else {
            return .failure("permission context is unavailable")
        }
        let question = try requiredString("question", from: parameters)
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              question.utf8.count <= 4_096 else {
            return .failure("question must be non-empty and at most 4096 UTF-8 bytes")
        }
        let workspaceID = try requiredUUID("workspaceID", from: parameters)
        guard runtime.allowedWorkspaceIDs.contains(workspaceID) else {
            return .failure("Workspace is not attached to this Ascendant")
        }
        guard let reader = runtime.workspaceReader else {
            return .failure("Workspace file access is unavailable")
        }
        guard let model = runtime.modelService else {
            return .failure("RLM model service is unavailable")
        }
        guard let reference = await reader.reference(id: workspaceID), reference.status == .available else {
            return .failure("Workspace is unavailable")
        }

        let prefixes = try pathPrefixes(from: parameters)
        let source = PositronicWorkspaceCorpusSource(workspaceID: workspaceID, reader: reader)
        let policy = RLMCorpusPolicy(allowedPathPrefixes: prefixes)
        let progress = RLMProgressReporter { _ in }
        let assembly: RLMRunAssembly
        do {
            assembly = try RLMRunAssemblyFactory.make(
                question: question,
                workspaceID: workspaceID,
                source: source,
                model: model,
                worker: worker,
                budget: .standard,
                policy: policy,
                progressSink: progress
            )
            try await assembly.evaluator.start()
        } catch let failure as RLMFailure {
            return .failure(failure.description)
        } catch {
            return .failure(String(describing: error))
        }

        let result: RLMRunResult
        result = await withTaskCancellationHandler(operation: {
            await assembly.engine.run(
                question: question,
                workspaceID: workspaceID.uuidString,
                source: source
            )
        }, onCancel: {
            Task { await assembly.evaluator.cancel() }
        })
        await assembly.evaluator.shutdown()

        switch result.outcome {
        case let .completed(answer, evidence):
            let output = RLMAnalysisOutput(
                answer: answer,
                evidence: evidence.map {
                    RLMEvidenceOutput(chunkID: $0.chunkID, path: $0.path, startLine: $0.startLine, endLine: $0.endLine)
                },
                metrics: RLMAnalysisMetricsOutput(
                    rootIterations: result.metrics.rootIterations,
                    leafModelCalls: result.metrics.leafModelCalls,
                    corpusFiles: result.metrics.corpusFiles,
                    corpusChunks: result.metrics.corpusChunks,
                    corpusBytes: result.metrics.corpusBytes,
                    contextReadBytes: result.metrics.contextReadBytes,
                    estimatedModelTokens: result.metrics.estimatedModelTokens,
                    evidenceReferences: result.metrics.evidenceReferences
                ),
                snapshotID: result.snapshotID
            )
            let encoded = try JSONEncoder().encode(output)
            return .success(String(decoding: encoded, as: UTF8.self))
        case let .failed(failure):
            return .failure(failure.description)
        case .cancelled:
            return .failure("RLM analysis cancelled")
        case .fenced:
            return .failure("RLM analysis result was fenced after cancellation")
        }
    }

    private func requiredString(_ name: String, from parameters: [String: AnyCodable]) throws -> String {
        guard let value = parameters[name]?.asString else {
            throw ToolError.invalidArgument(name, expected: "string", got: "missing or non-string")
        }
        return value
    }

    private func requiredUUID(_ name: String, from parameters: [String: AnyCodable]) throws -> UUID {
        let value = try requiredString(name, from: parameters)
        guard let id = UUID(uuidString: value) else {
            throw ToolError.invalidArgument(name, expected: "UUID string", got: value)
        }
        return id
    }

    private func pathPrefixes(from parameters: [String: AnyCodable]) throws -> [String] {
        guard let raw = parameters["pathPrefixes"] else { return [] }
        let prefixes: [String]
        if let values = raw.asArray {
            guard values.allSatisfy({ $0.asString != nil }) else {
                throw ToolError.invalidArgument("pathPrefixes", expected: "array of strings", got: "array with non-string item")
            }
            prefixes = values.compactMap(\.asString)
        } else if let text = raw.asString {
            prefixes = text.split(separator: ",", omittingEmptySubsequences: true).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            throw ToolError.invalidArgument("pathPrefixes", expected: "array of strings", got: "non-string and non-array")
        }
        guard prefixes.count <= 32, prefixes.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
            throw RLMFailure.invalidToolArguments("pathPrefixes must contain at most 32 relative prefixes of 256 bytes each")
        }
        return prefixes
    }
}

struct RLMPositronicContribution: PositronicContribution {
    let runtime: PositronicContributionRuntimeContext
    let worker: RLMWorkerSelection

    let label = "rlm"

    func tools() -> [AnyTool] {
        [AnyTool(AnalyzeWorkspaceCorpusTool(runtime: runtime, worker: worker))]
    }
}

enum RLMPositronicExtension {
    static let value = PositronicExtension(
        name: "rlm",
        settingKeys: [
            .init(name: "worker", summary: "Bounded Scheme worker to use: guile or chibi."),
        ]
    ) { scope in
        guard let runtime = scope.runtimeContext else {
            throw AscendantBackendError.invalidConfiguration("RLM extension has no bound runtime capability context")
        }
        let rawWorker = try scope.stringSetting("worker") ?? RLMWorkerSelection.guile.rawValue
        guard let worker = RLMWorkerSelection(rawValue: rawWorker.lowercased()) else {
            throw AscendantBackendError.invalidConfiguration("RLM extension worker must be guile or chibi")
        }
        return RLMPositronicContribution(runtime: runtime, worker: worker)
    }
}
