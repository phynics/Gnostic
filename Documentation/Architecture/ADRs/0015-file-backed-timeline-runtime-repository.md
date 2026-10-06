# ADR 0015 — File-backed Timeline runtime repository

## Status

Accepted. Owning issue:
[#531 — file-backed TimelineRuntimeRepository for cross-restart backend
transcripts](https://github.com/phynics/Gnostic/issues/531), under the
experimentation-platform umbrella
[Epic #140](https://github.com/phynics/Gnostic/issues/140) and
[RESET-001 #145](https://github.com/phynics/Gnostic/issues/145). Builds on
[ADR 0014](0014-durable-turn-event-log.md), which delivered the append-only log
primitive but deferred backend transcript durability, and on
[ADR 0005](0005-core-positronic-dependency-boundary.md), which keeps the kernel
below the kit.

This record **supersedes the process-scoped requirement in
[ADR 0008](0008-runtime-created-timeline-durability.md)** wherever the durable
store is configured. ADR 0008's interim orphaned-session behavior stays the
default for the in-memory path.

## Context

ADR 0008 accepted that a Timeline created at runtime through `session/new` did
not have to survive a `gnostic serve` restart. `PositronicAscendantAdapter`
held an `InMemoryTimelineRuntimeRepository` for the serve lifetime, so a restart
lost admission, tool intents and results, quarantine, summaries, and messages.
A restarted Node then advertised the Ascendant under a new provider identity and
`session/resume` failed with `timelineUnavailable`.

ADR 0014 delivered `AppendOnlyEventLog<Payload>` and deliberately did not build
a durable `TimelineRuntimeRepository`. The PositronicKit protocol combines
persistence with the message store: one faithful implementation owns admission,
tool intents and results, quarantine, summaries, cascade delete, and workspace
bindings. That work was deferred to its own issue, which is this record.

## Decision

### Compose and replay

`FileTimelineRuntimeRepository`
(`Sources/GnosticCore/Adapters/FileTimelineRuntimeRepository.swift`) is an
`actor` that wraps `InMemoryTimelineRuntimeRepository(isDurable: true)` and an
`AppendOnlyEventLog<JournaledOperation>`. Every mutating protocol method runs
the in-memory mutation first and journals the **resolved input** of that
mutation only when it actually changed state. Journaling after the mutation
means a journal failure never corrupts live state, and a rejected or dry-run
call writes nothing.

`init(fileURL:)` recovers the log and replays each operation through the
delegate, so the reconstructed repository holds the same Timeline records,
messages, Turns, tool intents and results, quarantine state, summaries, and
workspace bindings the live process held. `isDurable` is `true`.

### One file per Ascendant

`NodeAssembly` creates one repository per Ascendant at
`<state-home>/timelines/<ascendant-id>.jsonl`. Each file carries its own
`fnv1a64` frame per record, so a torn tail costs at most the final mutation;
recovery returns the valid prefix and truncates the rest.

### Wiring through an optional capability

`BackendTimelineStoreCapability` is an `AscendantBackendOptionalCapability`
that holds both the `TimelineRuntimeRepository` and the
`WorkspaceBindingRepository` (the PositronicKit protocol does not make one
conform to the other). `NodeAssembly` attaches it to
`AscendantBackendServices`, and `AscendantBackendSupervisor` re-attaches it when
it reconstructs a backend after an eviction. `PositronicAscendantAdapter.init`
resolves the capability; without it, the adapter keeps its process-scoped
in-memory repository.

Plan seeding becomes insert-if-absent: a restart re-saves only Timelines the
store does not already know, so a durable record keeps its timestamps and the
journal does not grow with no-op writes.

`NodeRegistry` requires the configured operated Timelines to be a subset of the
projected set and adopts any extra projected Timeline as `provenance: .runtime`
when its `attachedAgentID` is a configured Ascendant. The restarted Node
therefore registers, advertises, and serves a runtime Timeline that the store
persisted.

### Opt-in, unchanged default

Durability turns on under the same state directory ADR 0014 established:
`--turn-log <path>` (its parent directory) or `GNOSTIC_STATE_HOME`, from which
`gnostic serve` derives `turn-events-v1.jsonl` and `timelines/`. With neither,
the default in-memory serve path is identical to ADR 0008.

### Known limitation: ephemeral audit metadata

Replay regenerates `TurnNotice.id` values and the `TurnQuarantine.createdAt`
that the in-memory cascade sets from the clock, because the delegate mints them
inside the mutation and the journal replays resolved inputs rather than the full
`TurnRecord`. Every caller-visible field — Timeline, message, Turn identity,
lifecycle, outcome, retry relation, reason, timestamps, tool intent and result,
summary, and binding — is preserved. No Gnostic consumer reads `TurnNotice.id`.
If a host ever depends on notice identity across a restart, capture and replay
the full record instead.

### Content at rest

Unlike the Turn event log, this store writes backend transcript content
(`TimelineMessage` payloads) to disk, because a resumable session needs its
messages. It is opt-in with the state directory and confined to the per-Ascendant
transcript file.

## Rejected alternatives

- **A database (SQLite and friends).** ADR 0014 already rejected a schema and a
  system dependency for a bounded append-only case. The log primitive already
  provides crash-safe framing and torn-tail recovery.
- **Write a JSON snapshot on every mutation.** It rewrites the whole transcript
  per write, is not append-only, and a crash mid-write can lose the file rather
  than one record.
- **Identity-only durability.** ADR 0008 rejected it: a durable Node registry
  without a durable backend repository produces resumable-but-hollow sessions.
- **Journal the full `TurnRecord` after each mutation.** It duplicates state
  the resolved input already determines, and notice identity would still need a
  capture hook inside the delegate. The current limitation is documented instead.
- **Always-on durability.** It would change the default serve path and create
  state for operators who did not ask for it, exactly as ADR 0014 rejected.
- **One repository per Timeline.** Admission, quarantine, and summaries span
  the whole Ascendant, and workspace binding is Ascendant-scoped; one file per
  Ascendant keeps one writer and one replay order.

## Consequences

- A runtime-created Timeline and its backend transcript survive a `serve`
  restart when a state home is configured, so `session/resume` succeeds instead
  of orphaning.
- A restarted Node re-adopts the persisted runtime Timeline with
  `provenance: .runtime`; configured Timelines are unchanged.
- A torn tail costs at most the final mutation.
- The default in-memory serve path, the wire contract, and the manifest do not
  change.
- `TurnNotice.id` and cascade `TurnQuarantine.createdAt` are not stable across a
  restart. This is recorded above with a reconsideration trigger.
- ADR 0008's process-scoped requirement is superseded only when the store is
  configured; its interim orphaned-session contract remains the default.

## Reconsideration triggers

Reconsider when a host consumes `TurnNotice` identity or quarantine creation
time across a restart, when the transcript needs retention or rotation policy,
when a second writer must share an Ascendant file, or when concurrent `serve`
processes target the same state directory.

## Fitness

This record is checked by `make verify`, `make docs-check`, `make acp-smoke`,
and `git diff --check`. Behavioral evidence:

- `FileTimelineRuntimeRepositoryTests` runs the PositronicKit
  `TimelineRuntimeRepositoryConformanceSuite` with required summary storage,
  round-trips every mutation across a fresh replay, proves a torn tail costs at
  most the final mutation, and covers cascade delete, pruning, workspace
  binding, and quarantine across replay.
- `NodeRegistryTests.persistedRuntimeTimelineIsAdopted` proves a projected
  runtime Timeline is adopted with `provenance: .runtime`.
- `ACPProviderAcceptanceTests.serveRestartResumesRuntimeTimelineSessions`
  proves the process seam: a real `gnostic serve`, killed with SIGKILL, restarts
  under `GNOSTIC_STATE_HOME` and resumes the ACP session. Its sibling
  `serveRestartOrphansRuntimeTimelineSessions` still proves the in-memory
  default.

The architecture fitness suite keeps
`Adapters/FileTimelineRuntimeRepository.swift` in the `GnosticCore` PositronicKit
dependency inventory of ADR 0005.

## Links

- [#531 — file-backed TimelineRuntimeRepository](https://github.com/phynics/Gnostic/issues/531)
- [Epic #140](https://github.com/phynics/Gnostic/issues/140)
- [RESET-001 #145](https://github.com/phynics/Gnostic/issues/145)
- [ADR 0008 — runtime-created Timeline durability](0008-runtime-created-timeline-durability.md)
- [ADR 0014 — durable Turn event log](0014-durable-turn-event-log.md)
- [ADR 0005 — Core PositronicKit dependency boundary](0005-core-positronic-dependency-boundary.md)
