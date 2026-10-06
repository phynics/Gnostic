// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation
import GnosticCore

/// `gnostic turn-log` — a read-only view of the durable Turn event log.
///
/// The command resolves the same log `gnostic serve` writes, verifies every
/// record checksum, lists the journaled turns, and reports a torn or corrupt
/// tail. It never truncates or creates the file: the writer-owned `recover()`
/// keeps that responsibility, and both paths share one decode walk.
struct TurnLogCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "turn-log",
        abstract: "Inspect the durable Turn event log without changing it.",
        discussion: """
        Lists the turns `gnostic serve` journaled, verifies each record checksum, \
        and reports a torn or corrupt tail. The command never writes to the log, \
        so a tail is left in place for the writer-owned recovery to truncate. \
        Resolve the log with --turn-log or GNOSTIC_STATE_HOME, exactly as \
        `gnostic serve` does.
        """
    )

    @Option(
        name: .customLong("turn-log"),
        help: "Path to the durable Turn event log (overrides GNOSTIC_STATE_HOME)."
    )
    var turnLogPath: String?

    @OptionGroup var formatOptions: OutputFormatOptions

    func run() async throws {
        let format = try formatOptions.resolved()
        let location = TurnLogLocation(turnLogPath: turnLogPath)
        guard let url = location.turnLogURL() else {
            throw ValidationError(
                "No Turn event log is configured; pass --turn-log or set GNOSTIC_STATE_HOME."
            )
        }
        let exists = FileManager.default.fileExists(atPath: url.path)
        let log = AppendOnlyEventLog<TurnEventRecord>(fileURL: url)
        let scan = try log.scan()
        let report = TurnLogReport(scan: scan, path: url.path, exists: exists)
        switch format {
        case .human:
            print(report.humanDescription())
        case .json:
            print(try JSONOutput.encode(report))
        }
        // A torn or corrupt tail is an integrity finding, not a clean read.
        if report.tail != nil {
            throw ExitCode(2)
        }
    }
}
