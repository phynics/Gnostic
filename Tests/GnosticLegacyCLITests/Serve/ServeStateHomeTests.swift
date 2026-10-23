// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing
@testable import GnosticLegacyCLI

/// The state-home resolution contract shared by `serve`. It resolves the Turn
/// log, historical backend storage, and authoritative Timeline journal paths.
///
/// ArgumentParser only exposes a usable value through its parsing entry
/// points, so each case parses the flags a real `gnostic serve` invocation
/// would receive.
@Suite("Serve state resolution")
struct ServeStateHomeTests {
    @Test("an explicit turn log path is used verbatim and derives the Timeline journal path")
    func explicitTurnLogPathWins() throws {
        let command = try ServeCommand.parse(["--turn-log", "/var/lib/gnostic/custom/turns.jsonl"])

        #expect(command.resolveTurnLogURL(environment: [:])?.path == "/var/lib/gnostic/custom/turns.jsonl")
        #expect(command.resolveTimelineStoreDirectory(environment: [:])?.path == "/var/lib/gnostic/custom/timelines")
        #expect(command.resolveTimelineJournalDirectory(environment: [:])?.path == "/var/lib/gnostic/custom/timeline-journals")
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
        #expect(
            command.resolveTimelineJournalDirectory(environment: ["GNOSTIC_STATE_HOME": "/srv/gnostic"])?.path
                == "/srv/gnostic/timeline-journals"
        )
    }

    @Test("an unset durable state home has no Timeline journal path")
    func unsetStateDirectoryStaysInMemory() throws {
        let command = try ServeCommand.parse([])

        #expect(command.resolveTurnLogURL(environment: [:]) == nil)
        #expect(command.resolveTimelineStoreDirectory(environment: [:]) == nil)
        #expect(command.resolveTimelineJournalDirectory(environment: [:]) == nil)
    }

    @Test("the turn log compaction bound defaults and accepts an override")
    func turnLogCompactionBoundResolution() throws {
        let defaulted = try ServeCommand.parse([])
        #expect(defaulted.resolveTurnLogMaxBytes() == AscendantTurnUpdateStore.defaultMaxJournalBytes)

        let overridden = try ServeCommand.parse(["--turn-log-max-bytes", "1048576"])
        #expect(overridden.resolveTurnLogMaxBytes() == 1_048_576)

        let disabled = try ServeCommand.parse(["--turn-log-max-bytes", "0"])
        #expect(disabled.resolveTurnLogMaxBytes() == 0)
    }
}
