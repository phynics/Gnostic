// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PKShared
import PositronicKit

/// The interactive line loop for `gnostic chat`.
///
/// Reads lines from an injectable source (stdin in production, a scripted
/// iterator in tests), dispatches slash-commands, and runs turns through a
/// `ChatSession`. Unhandled errors keep the REPL alive.
public final class ChatREPL: Sendable {
    private let session: ChatSession
    private let timelineID: UUID
    private let approval: any ToolApprovalPolicy
    private let readLine: @Sendable () -> String?

    /// Creates a REPL.
    ///
    /// - Parameters:
    ///   - session: The turn engine.
    ///   - timelineID: The active timeline shown by `/timeline`.
    ///   - approval: The permissioned-tool gate (unused by `ChatSession` but
    ///     retained for parity with the interactive path).
    ///   - readLine: The line source.
    public init(
        session: ChatSession,
        timelineID: UUID,
        approval: any ToolApprovalPolicy,
        readLine: @escaping @Sendable () -> String?
    ) {
        self.session = session
        self.timelineID = timelineID
        self.approval = approval
        self.readLine = readLine
    }

    /// Runs the loop until `/quit` or the line source ends.
    public func run() async {
        while let line = readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("/") {
                if handleCommand(trimmed) { return }
                continue
            }
            do {
                let result = try await session.run(line: trimmed)
                switch result {
                case .text(let text): print(text)
                case .failed(let message): print("Error: \(message)")
                case .quit: return
                case .timeline: print("timeline: \(timelineID.uuidString.lowercased())")
                }
            } catch {
                print("Error: \(String(describing: error))")
            }
        }
        print("bye.")
    }

    /// Handles a slash command; returns true when the REPL should exit.
    private func handleCommand(_ line: String) -> Bool {
        switch line {
        case "/quit", "/exit":
            print("bye.")
            return true
        case "/timeline":
            print("timeline: \(timelineID.uuidString.lowercased())")
            return false
        default:
            print("Unknown command '\(line)'. Try /quit or /timeline.")
            return false
        }
    }
}