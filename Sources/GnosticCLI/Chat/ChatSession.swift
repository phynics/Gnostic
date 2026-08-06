// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PositronicKit
import PKShared

/// The result of one REPL turn.
public enum ChatTurnResult: Sendable, Equatable {
    /// The assistant's final text.
    case text(String)
    /// The turn failed (LLM error, tool failure, etc.).
    case failed(String)
    /// The user quit.
    case quit
    /// The user asked for timeline info.
    case timeline(UUID)
}

/// A minimal, scriptable chat turn engine.
///
/// Owns one PositronicKit timeline and runs `run(_:)` turns, extracting the
/// final assistant text from the event stream. Result and error surfaces are
/// deliberately small so tests can script full conversations through the same
/// code paths as the interactive REPL.
public final class ChatSession: Sendable {
    private let kit: PositronicKit
    private let tools: [any Tool]
    private let timelineID: UUID

    /// Creates a session over an existing kit and timeline.
    ///
    /// - Parameters:
    ///   - kit: The configured PositronicKit facade.
    ///   - tools: The tools offered to the model each turn.
    ///   - timelineID: The timeline turns run on.
    public init(kit: PositronicKit, tools: [any Tool], timelineID: UUID) {
        self.kit = kit
        self.tools = tools
        self.timelineID = timelineID
    }

    /// Runs one user line through PositronicKit and returns the outcome.
    ///
    /// - Parameter line: The user's message.
    /// - Returns: The turn result.
    public func run(line: String) async throws -> ChatTurnResult {
        let stream = try await kit.run(ChatRunRequest(
            timelineID: timelineID,
            message: line,
            tools: tools,
            maxTurns: 5
        ))
        var finalText = ""
        var lastError: String?
        do {
            for try await event in stream {
                switch event {
                case .completion(.generationCompleted(let message, _)):
                    finalText = message.content
                case .completion(.maxTurnsReached):
                    lastError = "The model exhausted its turn budget without a final answer."
                case .error(.error(let message, _)):
                    lastError = message
                case .error(.generationCancelled):
                    lastError = "The generation was cancelled."
                default:
                    break
                }
            }
        } catch {
            return .failed(String(describing: error))
        }
        if let lastError {
            return .failed(lastError)
        }
        if finalText.isEmpty {
            return .failed("The model produced no text.")
        }
        return .text(finalText)
    }
}

/// Structured errors for the chat REPL.
public enum ChatREPLError: Error, Sendable, LocalizedError {
    case unconfiguredLLM
    case timelineCreationFailed
    case invalidCommand(String)

    public var errorDescription: String? {
        switch self {
        case .unconfiguredLLM:
            "No LLM is configured. Set llm.provider, llm.model, and llm.apiKey with `gnostic config set`."
        case .timelineCreationFailed:
            "Could not create a chat timeline."
        case let .invalidCommand(command):
            "Unknown command '\(command)'. Try /quit or /timeline."
        }
    }
}