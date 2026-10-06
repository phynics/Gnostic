# ADR 0014 — Durable Turn event log

## Status

Accepted. Owning issue:
[GNO-PLAT-P8 #461](https://github.com/phynics/Gnostic/issues/461), under the
experimentation-platform umbrella
[Epic #438](https://github.com/phynics/Gnostic/issues/438). Builds on
[ADR 0008](0008-runtime-created-timeline-durability.md), which deferred
serve-restart durability.

This record delivers the **Gnostic-owned Turn event log** and its crash
recovery. It does not deliver backend transcript durability or a file-backed
`TimelineRuntimeRepository`; both remain tracked by the follow-up issues named
under [Consequences](#consequences).

## Context

ADR 0008 keeps runtime-created Timelines **process-scoped**. The per-turn
update and replay store
(`Sources/GnosticCore/Runtime/AscendantTurnUpdateStore.swift`) lives only for
the serve lifetime: `start`, `append`, and `finish` mutate an in-memory actor,
so a serve restart loses every identified Turn's bounded replay ledger.

The P8 outcome is that "long-horizon runs survive restarts and crashes". Three
consumers need that durability through one mechanism:

1. **Crash recovery.** A restarted serve should replay the bounded updates it
   journaled instead of presenting an empty ledger.
2. **Replay input.** The P4 trace/replay kit already replays a Run against a
   recorded tape. A restarted Run should reconstruct a partial tape rather
   than start over.
3. **Experiment analysis.** Modules (Atlas, Context) need one shared
   persistence interface instead of one per module store.

The kernel must not gain a backend, a database, or the platform kit to get
this. ADR 0013 keeps `GnosticCore` below `GnosticKit` and free of module
dependencies.

## Decision

### One append-only log primitive

`AppendOnlyEventLog<Payload>` (`Sources/GnosticCore/Persistence/`) is a
`Sendable`, stateless value. It stores one self-framed record per line:

```text
<fnv1a64-hex> <unix-milliseconds> <utf8-json>\n
```

`append` opens, seeks to the end, writes, flushes, and closes per call, so the
value is safe to hold from any actor. `recover` verifies each record. Because
the format is append-only and self-framing, a crash can only tear the final
record: recovery returns every valid record before the first unreadable one and
truncates the file to the valid prefix.

The primitive owns no Gnostic type. Any layer that can define a `Codable`,
`Sendable`, `Equatable` payload persists through it.

### Kernel adopter: the identified Turn ledger

`AscendantTurnUpdateStore` gains an optional journal of `TurnEventRecord`
(`started(messageDigest:)`, `update(AscendantTurnUpdate)`, `finished`).
`enableDurability(at:)` recovers the records and rebuilds the same bounded
ledger — including compaction — that the live process held. Journaling writes
after the in-memory mutation, so a journal failure never corrupts live state.

### Durability is opt-in

The default `gnostic serve` path is unchanged. Durability turns on only when a
log location is configured: `--turn-log <path>`, else a state directory in
`GNOSTIC_STATE_HOME` (`turn-events-v1.jsonl`). With neither, the store stays
in-memory, exactly as ADR 0008 describes.

### Kit adopter: the Run tape

`ExperimentTraceJournal` wraps the same log for `ExperimentTraceEvent`.
`ExperimentTraceRecorder.enableJournal(at:)` recovers a partial tape and
continues its current Turn, so a crashed Run resumes recording instead of
overwriting it.

### Privacy

The journal stores bounded update payloads and the prompt **digest**, never
prompt text. Conflict detection on replay still works, and no conversation
content is written at rest by this decision.

### Boundary

This decision does **not** make backend transcripts survive a restart. A
restarted serve still cannot resume a runtime-created Timeline's backend
session, per ADR 0008. Closing that gap needs a durable
`TimelineRuntimeRepository`, which owns admission, tool intents and results,
quarantine, summaries, and cascade delete.

## Rejected alternatives

- **A file-backed `TimelineRuntimeRepository` now.** The PositronicKit
  `TimelineRuntimeRepository` protocol combines persistence with the message
  store. Implementing it faithfully means admission, tool intent/result
  capture, quarantine, summaries, and cascade delete — a large, high-risk
  change that would not fit one reviewable increment. Deferred to its own
  issue.
- **Always-on durability.** It would change the default serve path, create
  state for operators who did not ask for it, and couple a write to every
  Turn. Opt-in keeps the default behavior identical to ADR 0008.
- **SHA-256 framing.** The kernel would need the kit's `ExperimentDigest` or a
  crypto dependency to get it. The checksum exists to detect a torn or corrupt
  tail, not to prove authenticity; FNV-1a 64 is enough and adds no dependency.
- **Persist prompt text.** It would put conversation content at rest and
  widen the privacy surface for no gain. The digest is enough for conflict
  detection.
- **A database (SQLite and friends).** It adds a system dependency and a
  schema-migration burden to the kernel for a bounded append-only case.
- **Per-module persistence.** Atlas and Context would each grow a private
  file format and recovery path. One shared interface keeps module stores
  consistent and testable.

## Consequences

- A restarted serve replays journaled identified Turns, including their
  compaction and message digest.
- A crashed experiment Run resumes its tape from the last durable event.
- A partial or torn final record costs at most that record; recovery truncates
  it and keeps the valid prefix.
- The kernel gains one dependency-free file under `Persistence/`.
- The default in-memory serve path and the wire contract do not change.
- Backend transcript durability and a file-backed `TimelineRuntimeRepository`
  remain open work, with Atlas and Context adoption as separate follow-ups.

## Reconsideration triggers

Reconsider when a durable `TimelineRuntimeRepository` lands, when a consumer
needs cross-restart backend transcript resume, when the log needs retention or
rotation policy, or when the checksum must detect tampering rather than
torn writes.

## Fitness

This record is checked by `make verify`, `make docs-check`, and
`git diff --check`. The architecture fitness suite already scans `GnosticCore`
sources for forbidden imports; the `Persistence/AppendOnlyEventLog.swift` file
must import only `Foundation`. The behavioral evidence is the focused test
suite: the primitive round-trips, truncates a torn tail, and refuses a corrupt
middle record; the store replays a restarted ledger with compaction and digest
intact and skips a start beyond its live retention bound. The default serve path
adds no file and no write.

## Links

- [GNO-PLAT-P8 #461 — durable Turn event log](https://github.com/phynics/Gnostic/issues/461)
- [Epic #438 — experimentation platform](https://github.com/phynics/Gnostic/issues/438)
- [ADR 0008 — runtime-created Timeline durability](0008-runtime-created-timeline-durability.md)
- [ADR 0013 — experimentation platform layering](0013-experimentation-platform.md)
- [ADR 0005 — Core PositronicKit dependency boundary](0005-core-positronic-dependency-boundary.md)
