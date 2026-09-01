# ADR 0006 — Timeline-bound backend execution

## Status

Accepted. Delivered by [architecture issue #194](https://github.com/phynics/Gnostic/issues/194), following Turn foundation [#191](https://github.com/phynics/Gnostic/issues/191), Timeline rename [#192](https://github.com/phynics/Gnostic/issues/192), and Workspace sessions [#193](https://github.com/phynics/Gnostic/issues/193).

## Context

The backend adapter boundary previously exposed Ascendant-wide operations that
accepted a Timeline ID on each call. That shape forced Gnostic services to
reconstruct or scan backend state, made provider-native execution state
operation-local, and left lifecycle fencing spread across callers. Turn,
rename, and Workspace operations also needed the same identity and retirement
guarantees.

## Decision

Bind single-Timeline execution to an operation-scoped backend Timeline session.
The backend-native session owns direct Timeline lookup and native state such as
PositronicKit's `ThreadHandle`. A Gnostic leased wrapper retains that session
for the operation and owns admission generation, lease validation,
cancellation, quarantine, projection validation, and suppression of late
updates. Collection operations remain on an Ascendant session: listing,
creation, and removal are not Timeline-session operations.

`NodeRegistry` remains authoritative for canonical identity, relationships,
revisions, Workspace intent, and projection commits. Rename and Workspace
mutations return a validated post-mutation projection so the backend mutation
and Gnostic commit can be coordinated without a mutate-then-fetch sequence.
Failures after a successful backend mutation are compensated through the same
leased session; a retired session cannot mutate or roll back a replacement.

The Swift adapter contract is a deliberate clean source break. The old flat
Turn and rename methods, backend-wide Workspace capability, compatibility
aliases, adapters, and dual-path calls are removed without deprecation or
migration shims. Network, manifest, ACP, wire-protocol, and persisted identity
contracts remain unchanged. Provider-native types remain behind the adapter
boundary.

## API mapping

| Removed API | Replacement |
| --- | --- |
| `AscendantBackendTurnRequest` and `AscendantBackend.runTurn` | `AscendantBackendTimelineTurnRequest` and `AscendantBackendTimelineSession.runTurn` |
| `AscendantBackend.renameTimeline` | `AscendantBackendTimelineSession.rename` |
| `AscendantBackendWorkspaceCapability` with Timeline IDs | `AscendantBackendTimelineWorkspaceSession.attachWorkspace`, `detachWorkspace`, and `enabledToolIDs` |
| Per-Timeline `operatedTimelines()` lookup | `AscendantBackend.timeline(id:)`, acquired through a leased Ascendant session |
| `AscendantBackendTimeline.attachedAscendantID` compatibility spelling | `AscendantBackendTimeline.ascendantID` |
| Callback-shaped service backend arguments | Internal `BackendSessionProviding` and operation-scoped leased sessions |

## Consequences

Services acquire operation-scoped sessions and never cache them or receive a
raw backend. Direct lookup is required for every single-Timeline operation,
while `operatedTimelines()` is reserved for collection and startup/recovery
work. Lifecycle failures and adapter contract violations are quarantined only
when their originating lease is still current; ordinary model, tool,
permission, terminal, and cancellation failures are caller-visible without
quarantine.

The source break requires all in-repository adapters and fixtures to move to
the session contract at once. In return, Timeline identity, native execution
state, lifecycle fencing, and projection commit ownership are explicit and
testable at one seam.

## Rejected alternatives

- Keeping flat backend methods with Timeline IDs would preserve reconstruction,
  scanning, and duplicated lifecycle policy in services.
- Returning a projection through a separate fetch method would reintroduce a
  race between mutation and readback.
- Retaining deprecated aliases or default adapters would leave two lifecycle
  paths and allow the removed contract to return.
- Moving canonical relationships or revision commits into backend sessions
  would make provider state authoritative over Gnostic identity.

## Reconsideration triggers

Reconsider the session boundary only if a future backend contract can preserve
native per-Timeline execution state, current-only lifecycle fencing, and atomic
projection coordination without operation-scoped sessions. Reconsider the
clean source-break policy when a separately versioned public adapter package
requires a deliberate migration protocol.

## Links

- [ADR 0001 — Axoloty-native multi-backend host](0001-axoloty-native-multi-backend-host.md)
- [ADR 0002 — Gnostic identity versus backend state](0002-gnostic-identity-vs-backend-state.md)
- [ADR 0005 — Core PositronicKit dependency boundary](0005-core-positronic-dependency-boundary.md)
- [Architecture epic #140](https://github.com/phynics/Gnostic/issues/140)
- [Turn foundation #191](https://github.com/phynics/Gnostic/issues/191)
- [Timeline rename #192](https://github.com/phynics/Gnostic/issues/192)
- [Workspace sessions #193](https://github.com/phynics/Gnostic/issues/193)
- [Contract cleanup #194](https://github.com/phynics/Gnostic/issues/194)
