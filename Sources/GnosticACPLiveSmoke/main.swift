// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticACPAscendant
import GnosticCore

private enum SmokeError: Error, CustomStringConvertible {
    case usage
    case missingAuthentication(String)
    case turnDidNotWriteFile

    var description: String {
        switch self {
        case .usage:
            "Usage: gnostic-acp-live-smoke <opencode|codex|claude-agent>"
        case let .missingAuthentication(agent):
            "No supported login or API credential was detected for \(agent)."
        case .turnDidNotWriteFile:
            "The agent did not create the expected file in the isolated smoke directory."
        }
    }
}

private actor InteractivePermissionService: AscendantBackendPermissionService {
    func requestApproval(for request: BackendPermissionRequest) async -> AscendantPermissionDecision {
        print("\nPermission requested: \(request.title)")
        print("Approve this agent-owned tool call in the isolated smoke directory? [y/N] ", terminator: "")
        guard let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), answer == "y" else {
            print("Permission denied.")
            return .denied
        }
        print("Permission approved.")
        return .approved
    }
}

private actor ConsoleUpdateSink: AscendantBackendUpdateSink {
    func append(_ update: AscendantBackendUpdate) async throws {
        if let toolState = update.toolState {
            print("[tool state] \(toolState)")
        }
        if let permissionState = update.permissionState {
            print("[permission state] \(permissionState)")
        }
        if let text = update.text, !text.isEmpty {
            print("[agent] \(text)")
        }
    }
}

@main
private struct ACPLiveSmoke {
    @MainActor
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("ACP live smoke failed: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }

    @MainActor
    private static func run() async throws {
        guard CommandLine.arguments.count == 2,
              let agent = Agent(rawValue: CommandLine.arguments[1])
        else { throw SmokeError.usage }
        try agent.requireAuthentication()

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-acp-live-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let ascendantID = UUID()
        let timelineID = UUID()
        let environment = ProcessInfo.processInfo.environment
        let secrets = agent.secretEnvironment(environment).mapValues(ManifestJSONValue.string)
        let configuration = AscendantBackendConfiguration(
            kind: ACPAscendantBackend.kind,
            settings: [
                "command": .string(agent.command),
                "args": .string(try jsonString(agent.arguments)),
                "cwd": .string(workDirectory.path),
                "displayName": .string(agent.displayName),
            ],
            secrets: secrets
        )
        let ascendant = NodeManifest.Ascendant(
            id: ascendantID,
            name: agent.displayName,
            defaultTimelineID: timelineID,
            backend: configuration
        )
        let timeline = NodeManifest.Timeline(id: timelineID, title: "ACP live smoke")
        let backend = try ACPAscendantBackend(
            ascendant: ascendant,
            configuration: configuration,
            services: AscendantBackendServices(permission: InteractivePermissionService()),
            timelines: [timeline]
        )
        defer { Task { await backend.shutdown() } }

        print("Starting one live \(agent.displayName) Turn. Work directory: \(workDirectory.path)")
        print("The agent owns its tools. Review and approve each permission request.")
        let reply = try await backend.runTurn(
            .init(
                timelineID: timelineID,
                message: "Use your own tools to create a file named gnostic-acp-live-smoke.txt in the current working directory containing exactly acp-live-smoke-ok, then read it back and tell me its contents. Do not claim success unless both tool actions succeed.",
                clientTurnID: "live-smoke-\(UUID().uuidString.lowercased())"
            ),
            updates: ConsoleUpdateSink()
        )

        let resultURL = workDirectory.appendingPathComponent("gnostic-acp-live-smoke.txt")
        guard let fileContents = try? String(contentsOf: resultURL, encoding: .utf8),
              fileContents.trimmingCharacters(in: .whitespacesAndNewlines) == "acp-live-smoke-ok"
        else { throw SmokeError.turnDidNotWriteFile }
        print("[final] \(reply)")
        print("PASS: agent created and read the expected file in its temporary directory.")
        await backend.shutdown()
    }

    private static func jsonString(_ values: [String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: values)
        guard let value = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return value
    }
}

private enum Agent: String {
    case opencode
    case codex
    case claudeAgent = "claude-agent"

    var displayName: String {
        switch self {
        case .opencode: "opencode"
        case .codex: "Codex"
        case .claudeAgent: "Claude Agent"
        }
    }

    var command: String {
        switch self {
        case .opencode: "opencode"
        case .codex: "npx"
        case .claudeAgent: "claude-agent-acp"
        }
    }

    var arguments: [String] {
        switch self {
        case .opencode: ["acp"]
        case .codex: ["--yes", "@agentclientprotocol/codex-acp@1.13.1"]
        case .claudeAgent: []
        }
    }

    func requireAuthentication() throws {
        let environment = ProcessInfo.processInfo.environment
        let authenticated: Bool
        switch self {
        case .opencode:
            authenticated = FileManager.default.fileExists(atPath: "\(NSHomeDirectory())/.local/share/opencode/auth.json")
        case .codex:
            authenticated = environment["CODEX_API_KEY"] != nil
                || environment["OPENAI_API_KEY"] != nil
                || FileManager.default.fileExists(atPath: "\(NSHomeDirectory())/.codex/auth.json")
        case .claudeAgent:
            authenticated = environment["ANTHROPIC_API_KEY"] != nil
                || FileManager.default.fileExists(atPath: "\(NSHomeDirectory())/.claude/.credentials.json")
        }
        guard authenticated else { throw SmokeError.missingAuthentication(displayName) }
    }

    func secretEnvironment(_ environment: [String: String]) -> [String: String] {
        switch self {
        case .opencode: [:]
        case .codex:
            if let value = environment["CODEX_API_KEY"] { ["env-secret.CODEX_API_KEY": value] }
            else if let value = environment["OPENAI_API_KEY"] { ["env-secret.OPENAI_API_KEY": value] }
            else { [:] }
        case .claudeAgent:
            if let value = environment["ANTHROPIC_API_KEY"] { ["env-secret.ANTHROPIC_API_KEY": value] }
            else { [:] }
        }
    }

}
