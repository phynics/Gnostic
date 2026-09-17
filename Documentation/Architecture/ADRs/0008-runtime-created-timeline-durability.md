# ADR 0008 — Runtime-created Timeline durability across serve restarts

## Status

Accepted. Requirement decision: runtime-created Timelines remain
**process-scoped** in the current contract. Serve-restart session durability is
deferred to a future feature with its own owning issue, because it needs a
durable backend transcript store in addition to a Gnostic identity store.

The interim ACP behavior for sessions whose Timeline no longer exists is
specified below. Delivering that behavior depends on
[#247](https://github.com/phynics/Gnostic/issues/247) removing the per-process
provider pin.

## Context

`gnostic acp` `session/new` creates a Timeline at runtime through
`ACPDispatcher.newSession`
(`Sources/GnosticCLI/ACP/ACPDispatcher.swift:104`), `RemoteTurnClient.createTimeline`
(`Sources/GnosticCLI/ACP/RemoteTurnClient.swift:230`), and `TimelineService.create`
(`Sources/GnosticCore/Runtime/TimelineService.swift:66`). The Positronic adapter
records the new Timeline in two in-memory places:

- `PositronicAscendantAdapter.createTimeline` saves a `Thread` into an
  `InMemoryThreadRuntimeRepository` constructed per adapter
  (`Sources/GnosticCore/Adapters/PositronicAscendantAdapter.swift:75`, `:265`).
- `NodeRegistry.registerRuntimeTimeline` records `provenance: .runtime` in
  process memory (`Sources/GnosticCore/Runtime/NodeRegistry.swift:222`).

Nothing writes runtime Timeline identity to disk. The registry is rebuilt from
the manifest launch plan on every process start
(`Sources/GnosticCore/Runtime/NodeAssembly.swift:162`), and
`NodeRegistry.backendReconstructionState` only re-derives Timelines inside a
running process (`Sources/GnosticCore/Runtime/NodeRegistry.swift:379`). The ACP
session registry, by contrast, is durable metadata
(`Sources/GnosticCLI/ACP/ACPSessionRegistry.swift:5`). A restarted serve can
therefore list ACP sessions it can no longer serve, which is the gap found in
[#239](https://github.com/phynics/Gnostic/issues/239).

Conversation content is ephemeral for configured Timelines too. The adapter
re-seeds `Thread` metadata at startup but never messages
(`Sources/GnosticCore/Adapters/PositronicAscendantAdapter.swift:83`), and the
per-turn update and replay store lives only for the serve lifetime
(`Sources/GnosticCore/Runtime/AscendantTurnUpdateStore.swift:5`). Run an ACP
`session/resume` after a serve restart and the resolved Timeline is gone even
when the ACP child kept its registry record.

## Decision

### Requirement

A Timeline created at runtime does **not** have to survive a `gnostic serve`
restart in the current contract. `session/resume` is promised across an ACP
child restart against a live serve, which the existing subprocess test covers.
It is not promised across a serve restart. Reconsider when a concrete user need
for cross-restart sessions is confirmed.

### Ownership and storage (if durability is required)

If durability becomes required, Gnostic owns a **node-scoped Timeline state
store**, separate from the manifest, that persists runtime Timeline identity,
title, operating Ascendant, provenance, timestamps, and attachment intent. The
store loads at `NodeAssembly.buildBackends` time and merges with the configured
manifest Timelines under the same lease and lifecycle-generation fencing the
registry uses now. The manifest stays configuration-only and is never written
back. The backend owns transcript and content and must be backed by a durable
`ThreadRuntimeRepository`; without a durable repository the identity store
alone produces resumable-but-hollow sessions.

### Interim ACP behavior for orphaned sessions

Until durability lands, and after #247 removes the per-process provider pin:

1. `session/resume` for a session whose remote Timeline is not discoverable
   fails with `timelineUnavailable` and the underlying
   `RemoteTurnClientError.timelineUnavailable(<uuid>)`, never a binding or
   provider error.
2. `session/list` omits records whose Timeline cannot be resolved. That is the
   current `timelineStatus` probe behavior
   (`Sources/GnosticCLI/ACP/ACPDispatcher.swift:149`); it becomes an explicit
   registry invariant with a regression test.
3. The registry keeps the on-disk record for diagnostics but marks it ended
   once the remote Timeline is confirmed absent, so a restarted ACP child does
   not retry indefinitely.
4. `session/prompt` on an orphaned session fails with `timelineUnavailable`
   before Turn admission and never creates a fresh backend Thread implicitly.
5. The ACP contract documents that resume is stable across an ACP-child
   restart, not across a serve restart.

## Rejected alternatives

- **Manifest as the runtime state store.** The manifest is copied into the
  registry at launch and runtime state must never be written back
  (`Sources/GnosticCore/Runtime/NodeRegistry.swift:7`). Writing runtime
  Timelines into it would mutate an operator's configuration at runtime and
  conflate configuration with output.
- **Backend as the owner of Gnostic Timeline identity.** ADR 0002 and
  `CONTEXT.md` state that a backend may project a Timeline into private state
  but cannot redefine or erase Gnostic identity. PositronicKit `Thread` and
  `AgentInstance` are backend-private; losing or replacing a backend would lose
  the Timeline.
- **Registry-only durability.** `ACPSessionRegistry` is a CLI projection, not
  the canonical domain store. It cannot reconstruct a backend Thread or
  transcript, and persisting identity there would duplicate it across layers
  while leaving `NodeRegistry` as the source of truth.
- **Make runtime Timelines durable now.** Identity durability needs both a
  Gnostic store and a durable backend repository, neither of which exists.
  Shipping identity-only durability would advertise resume for sessions that
  cannot replay their content.

## Consequences

- Runtime Timelines remain process-scoped. A serve restart orphans any ACP
  session created before it.
- `session/resume` and `session/list` reconcile against the live environment
  instead of trusting the durable ACP registry alone.
- Full cross-restart sessions stay out of scope until a durable Gnostic
  Timeline store, a durable backend `ThreadRuntimeRepository`, and a replay or
  idempotency durability decision all land.
- This decision changes no source, wire, manifest, ACP method, protocol-major,
  or persisted-identity contract. The interim behavior is tracked by
  [#277](https://github.com/phynics/Gnostic/issues/277) and depends on #247.

## Reconsideration triggers

Reconsider when a concrete user requirement for cross-restart ACP sessions is
confirmed, when a durable `ThreadRuntimeRepository` becomes available, or when
the ACP registry is asked to present sessions that a restarted serve cannot
serve.

## Fitness

This record is checked by `make docs-check`, `make verify`, and
`git diff --check`. The interim orphaned-session behavior requires a
broker-backed test that starts serve, creates a Timeline through ACP, kills
serve, restarts it, and asserts `timelineUnavailable` plus omission from
`session/list`. The decision adds no production dependency.

## Links

- [#248 — durability investigation](https://github.com/phynics/Gnostic/issues/248)
- [#239 — stale Ascendant presence after an unclean serve exit](https://github.com/phynics/Gnostic/issues/239)
- [#247 — bind ACP profiles and sessions to a stable node](https://github.com/phynics/Gnostic/issues/247)
- [ADR 0002 — Gnostic identity versus backend state](0002-gnostic-identity-vs-backend-state.md)
- [Epic #140](https://github.com/phynics/Gnostic/issues/140)
- [RESET-001 #145](https://github.com/phynics/Gnostic/issues/145)
