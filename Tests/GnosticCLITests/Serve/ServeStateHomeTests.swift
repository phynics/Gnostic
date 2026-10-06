// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing
@testable import GnosticCLI

/// The state-home resolution contract shared by `serve`. It decides whether a
/// process is durable and where the Turn log and Timeline transcripts land, so
/// the explicit, derived, and default cases are pinned here (ADR 0015).
///
/// ArgumentParser only exposes a usable value through its parsing entry
/// points, so each case parses the flags a real `gnostic serve` invocation
/// would receive.
@Suite("Serve state resolution")
struct ServeStateHomeTests {
    @Test("an explicit turn log path is used verbatim and shares its directory with timelines")
    func explicitTurnLogPathWins() throws {
        let command = try ServeCommand.parse(["--turn-log", "/var/lib/gnostic/custom/turns.jsonl"])

        #expect(command.resolveTurnLogURL(environment: [:])?.path == "/var/lib/gnostic/custom/turns.jsonl")
        #expect(command.resolveTimelineStoreDirectory(environment: [:])?.path == "/var/lib/gnostic/custom/timelines")
    }

    @Test("GNOSTIC_STATE_HOME derives both the turn log and the timeline directory")
    func stateHomeDerivesBothLocations() throws {
        let command = try ServeCommand.parse([])

        #expect(
            command.resolveTurnLogURL(environment: ["GNOSTIC_STATE_HOME": "/srv/gnostic"])?.path
                == "/srv/gnostic/turn-events-v1.jsonl"
        )
        #expect(
            command.resolveTimelineStoreDirectory(environment: ["GNOSTIC_STATE_HOME": "/srv/gnostic"])?.path
                == "/srv/gnostic/timelines"
        )
    }

    @Test("neither setting keeps the process-scoped default")
    func unsetStateDirectoryStaysInMemory() throws {
        let command = try ServeCommand.parse([])

        #expect(command.resolveTurnLogURL(environment: [:]) == nil)
        #expect(command.resolveTimelineStoreDirectory(environment: [:]) == nil)
    }
}
