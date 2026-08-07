// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PKShared
import PositronicKit

/// The interactive line loop for `gnostic chat`.
///
/// Reads lines from an injectable source (stdin in production, a scripted
/// iterator in tests), dispatches slash-commands, and runs turns through a
/// `ChatTurnRunning` session. Unhandled errors keep the REPL alive.
public final class ChatREPL: Sendable {
    private let session: any ChatTurnRunning
    private let timelineID: UUID
    private let approval: any ToolApprovalPolicy
    private let readLine: @Sendable () -> String?
    private let writeOutput: @Sendable (String) -> Void

    /// Creates a REPL.
    ///
    /// - Parameters:
    ///   - session: The turn engine (local or remote).
    ///   - timelineID: The active timeline shown by `/timeline`.
    ///   - approval: The permissioned-tool gate (unused by the turn engine but
    ///     retained for parity with the interactive path).
    ///   - readLine: The line source.
    ///   - writeOutput: The text sink (defaults to `print`).
    public init(
        session: any ChatTurnRunning,
        timelineID: UUID,
        approval: any ToolApprovalPolicy,
        readLine: @escaping @Sendable () -> String?,
        writeOutput: @escaping @Sendable (String) -> Void = { print($0) }
    ) {
        self.session = session
        self.timelineID = timelineID
        self.approval = approval
        self.readLine = readLine
        self.writeOutput = writeOutput
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
                case .text(let text): writeOutput(text)
                case .failed(let message): writeOutput("Error: \(message)")
                case .quit: return
                case .timeline: writeOutput("timeline: \(timelineID.uuidString.lowercased())")
                }
            } catch {
                writeOutput("Error: \(String(describing: error))")
            }
        }
        writeOutput("bye.")
    }

    /// Handles a slash command; returns true when the REPL should exit.
    private func handleCommand(_ line: String) -> Bool {
        switch line {
        case "/quit", "/exit":
            writeOutput("bye.")
            return true
        case "/timeline":
            writeOutput("timeline: \(activeTimelineID.uuidString.lowercased())")
            return false
        case "/timelines":
            Task {
                await showTimelines()
            }
            return false
        case "/new":
            Task {
                await createAndActivateTimeline()
            }
            return false
        case "/workspaces":
            Task {
                await showWorkspaces()
            }
            return false
        default:
            if line.hasPrefix("/use ") {
                let id = String(line.dropFirst("/use ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                switchTimeline(id: id)
                return false
            }
            if line.hasPrefix("/rename ") {
                let title = String(line.dropFirst("/rename ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                Task { await renameActiveTimeline(title: title) }
                return false
            }
            if line.hasPrefix("/attach ") {
                let id = String(line.dropFirst("/attach ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                Task { await mutateWorkspace(id: id, attach: true) }
                return false
            }
            if line.hasPrefix("/detach ") {
                let id = String(line.dropFirst("/detach ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                Task { await mutateWorkspace(id: id, attach: false) }
                return false
            }
            writeOutput("Unknown command '\(line)'. Try /quit, /timeline, /timelines, /new, /use <id>, /rename <title>, /workspaces, /attach <id>, /detach <id>.")
            return false
        }
    }

    /// The effective active timeline id: the session's when it is a remote
    /// session (which can switch), otherwise the REPL's initial timeline.
    private var activeTimelineID: UUID {
        (session as? RemoteChatSession)?.timelineID ?? timelineID
    }

    private func showTimelines() async {
        guard let remote = session as? RemoteChatSession else {
            writeOutput("Timeline commands are only available against a serve agent.")
            return
        }
        do {
            let timelines = try await remote.listTimelines()
            if timelines.isEmpty {
                writeOutput("(no timelines)")
                return
            }
            let active = activeTimelineID
            for tl in timelines {
                let marker = tl.timelineID == active ? "* " : "  "
                writeOutput("\(marker)\(tl.timelineID.uuidString.lowercased()) \(tl.title)")
            }
        } catch {
            writeOutput("Error: \(String(describing: error))")
        }
    }

    private func createAndActivateTimeline() async {
        guard let remote = session as? RemoteChatSession else {
            writeOutput("Timeline commands are only available against a serve agent.")
            return
        }
        do {
            let status = try await remote.createActivateTimeline(title: "New Conversation")
            writeOutput("created + active: \(status.timelineID.uuidString.lowercased()) \(status.title)")
        } catch {
            writeOutput("Error: \(String(describing: error))")
        }
    }

    private func switchTimeline(id: String) {
        guard let remote = session as? RemoteChatSession,
              let timelineID = UUID(uuidString: id) else {
            writeOutput("Invalid timeline id '\(id)' or no serve agent.")
            return
        }
        remote.switchTimeline(to: timelineID)
        writeOutput("active timeline \(timelineID.uuidString.lowercased())")
    }

    private func renameActiveTimeline(title: String) async {
        guard let remote = session as? RemoteChatSession else {
            writeOutput("Timeline commands are only available against a serve agent.")
            return
        }
        do {
            let status = try await remote.renameActiveTimeline(title: title)
            writeOutput("renamed: \(status.timelineID.uuidString.lowercased()) \(status.title)")
        } catch {
            writeOutput("Error: \(String(describing: error))")
        }
    }

    private func showWorkspaces() async {
        guard let remote = session as? RemoteChatSession else {
            writeOutput("Workspace commands are only available against a serve agent.")
            return
        }
        do {
            let attached = try await remote.attachedWorkspaceIDs()
            if attached.isEmpty {
                writeOutput("(no attached workspaces)")
            } else {
                writeOutput("attached:")
                for id in attached { writeOutput("  \(id.uuidString.lowercased())") }
            }
            let attachable = try await remote.attachableWorkspaces()
            if !attachable.isEmpty {
                writeOutput("attachable:")
                for w in attachable { writeOutput("  \(w.id.uuidString.lowercased()) \(w.name)") }
            }
        } catch {
            writeOutput("Error: \(String(describing: error))")
        }
    }

    private func mutateWorkspace(id: String, attach: Bool) async {
        guard let remote = session as? RemoteChatSession,
              let workspaceID = UUID(uuidString: id) else {
            writeOutput("Invalid workspace id '\(id)' or no serve agent.")
            return
        }
        do {
            let ok = attach ? try await remote.attach(workspaceID) : try await remote.detach(workspaceID)
            writeOutput(ok ? (attach ? "attached \(id)" : "detached \(id)") : "operation denied")
        } catch {
            writeOutput("Error: \(String(describing: error))")
        }
    }
}