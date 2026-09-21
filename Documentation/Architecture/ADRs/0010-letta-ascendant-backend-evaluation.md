# ADR 0010 — Letta as the first non-Positronic Ascendant backend

## Status

Accepted evaluation outcome: **PROTOTYPE**. Delivered by
[#246](https://github.com/phynics/Gnostic/issues/246) under epic
[#241](https://github.com/phynics/Gnostic/issues/241).

The Letta backend is an optional, experimental downstream target
(`GnosticLettaBackend`). It is not production support. The decision also
re-evaluates the extraction trigger in
[ADR 0005](0005-core-positronic-dependency-boundary.md).

Delivery is checked by [Epic #140](https://github.com/phynics/Gnostic/issues/140)
and [RESET-001 #145](https://github.com/phynics/Gnostic/issues/145)
documentation and architecture gates.

## Context

[ADR 0002](0002-gnostic-identity-vs-backend-state.md) keeps Ascendant and
Timeline identity Gnostic-owned while a backend owns transcript, memory, and
provider-native state. [ADR 0005](0005-core-positronic-dependency-boundary.md)
defers extracting the bundled Positronic adapter until "a second backend is
shipped". [ADR 0009](0009-multi-configuration-ascendant-hosting.md) allows an
optional experiment target outside `GnosticCore` and requires the flat
`AscendantBackend` contract on `main` as the only integration point
([ADR 0007](0007-timeline-bound-backend-session-contract-disposition.md)).

[#246](https://github.com/phynics/Gnostic/issues/246) asks whether Letta can
implement `AscendantBackend` from an optional target without a Core change. It
names one disqualifier: if Letta could only run tools server-side, Gnostic
permission mediation would be bypassed.

## Decision

Letta can implement the flat contract from an optional target. Ship a
fixture-backed prototype and record the mapping.

### Identity and state mapping

Use **one Letta agent per Ascendant** and **one Letta conversation per Gnostic
Timeline**. A Letta agent owns identity and long-term memory, which matches the
Ascendant; a conversation is a message thread with its own context window that
shares the agent's memory, which matches a Timeline. The Ascendant's private
Timeline uses the agent's default conversation.

Timeline identity stays Gnostic-owned. The backend writes the Gnostic Timeline
UUID into the conversation description as a `[gnostic:<uuid>]` marker. That
makes the projection recoverable from remote state alone:

- `createTimeline(id:title:)` lists conversations, returns the existing
  projection when the marker is present, and otherwise creates one conversation.
  Repeating the call creates nothing new.
- `removeTimeline(id:)` deletes the conversation that carries the marker and
  drops local state. Removing an unknown Timeline is a no-op.
- `renameTimeline(id:title:)` updates the conversation description and throws
  `timelineNotFound` for a Timeline the backend does not operate.
- `operatedTimelines()` returns the Gnostic-keyed projections without a network
  call, so Node assembly cannot fail on a server outage.

The agent itself is resolved lazily on the first operation, by name and by a
`gnostic.ascendant` metadata marker, so an existing agent is reused.

### Tool execution

Letta supports client-side tools. A caller passes `client_tools` on the
`messages` request; when the model calls one, the server pauses and returns an
approval request. The caller executes the tool and returns the result, and the
agent continues. This is exactly the host-execution seam Gnostic needs.

The backend passes the attached Workspace tools as `client_tools`, maps an
approval request to `(workspaceID, toolID)`, mediates it through
`AscendantBackendPermissionService` when the tool requires permission, executes
it through `AscendantBackendWorkspaceService.invoke`, and returns the result.
Server-side execution is never used for a Gnostic Workspace, so permission
mediation is preserved. A denied decision never reaches the Workspace.

### Streaming and cancellation

The backend maps Letta Server-Sent-Events messages to
`AscendantBackendUpdateSink` updates: assistant text, tool state, and a terminal
completion. `cancel()` calls the conversation cancel endpoint and the in-flight
stream ends; the backend raises `AscendantBackendError.cancelled`. Cancellation
is best-effort, as [ADR 0002](0002-gnostic-identity-vs-backend-state.md)
requires: late provider completion is rejected by the host generation and lease
checks.

### Health and lifecycle

A transport or connection failure maps to
`AscendantBackendError.lifecycleUnusable`, which quarantines the Ascendant and
allows one bounded reconstruction. A provider stop reason that is not
cancellation (`llm_api_error`, `max_steps`, and similar) maps to
`AscendantBackendError.terminal`, which leaves the backend usable. The
`GET /v1/health/` endpoint is available for a liveness probe.

### Configuration

The backend advertises `serverURL`, `model`, `agentID`, `agentName`, and
`maxSteps` settings and one `apiKey` secret. These live in the existing backend
envelope, so `gnostic config backend keys` lists them and `config backend
set-secret` stores the credential. The kind is registered through the composition
source from [#242](https://github.com/phynics/Gnostic/issues/242)
(`BackendComposition`), not in `GnosticCore`.

### Evidence

- `GnosticCore` has no Letta dependency; the new target is `GnosticLettaBackend`.
- The prototype passes fixture-backed tests for Turn, streaming, cancellation,
  permission mediation, Workspace tool execution, Timeline idempotency, and
  failure classification, plus a real loopback HTTP fixture server for the
  `URLSession` transport.
- A mixed-configuration Node hosts a Letta Ascendant beside a non-Positronic
  fixture Ascendant and passes Turn, Workspace tool, cancellation, and shutdown.

Sources consulted (Letta documentation, September 2026):

- Client tools: <https://docs.letta.com/guides/core-concepts/tools/client-tools>
- Streaming: <https://docs.letta.com/v1-sdk/messages/streaming>
- Conversations: <https://docs.letta.com/v1-sdk/messages/conversations>
- Cancel message: <https://docs.letta.com/api/resources/agents/subresources/messages/methods/cancel>
- Cancel conversation: <https://docs.letta.com/api/resources/conversations/methods/cancel>
- Health: <https://docs.letta.com/api/resources/$client/methods/health>
- Create message: <https://docs.letta.com/api/resources/agents/subresources/messages/methods/create>
- List agents: <https://docs.letta.com/api/resources/agents/methods/list>

### Not proven

The prototype does not use live Letta credentials, so no live server was
exercised. Provider-side cancellation of an active run needs Redis on a
self-hosted server; the prototype treats cancellation as best-effort. Node-level
permission response driving is covered at the backend seam because
`NodeRuntime` exposes no in-process permission-response API.

## ADR 0005 extraction trigger

Re-evaluated, and **not triggered**. ADR 0005 reconsideration requires that "a
second backend is shipped". An optional, experimental, fixture-backed prototype
is not a shipped backend. The prototype shows the flat contract hosts a
non-Positronic backend with no Core change and no new package boundary, so
extraction remains deferred under the original conditions: a shipped second
backend, an independent release/ownership boundary for the Positronic adapter,
or a measured Core build benefit.

## Rejected alternatives

- **ARCHIVE because only server-side tools are possible.** Rejected. Letta
  client tools hand tool calls back to the host, so permission mediation is not
  bypassed.
- **ARCHIVE because the contract cannot be implemented.** Rejected. The flat
  contract maps cleanly; the prototype implements and tests it.
- **Core dependency on Letta.** Rejected by
  [ADR 0009](0009-multi-configuration-ascendant-hosting.md). The target stays
  outside Core and reaches the host only through `AscendantBackend`.
- **Re-landing the Timeline-session contract for Letta.** Rejected by
  [ADR 0007](0007-timeline-bound-backend-session-contract-disposition.md). The
  flat contract is sufficient.
- **One Letta agent per Timeline.** Rejected because it would split Ascendant
  memory across agents and contradict the Ascendant as one logical identity.

## Consequences

- A non-Positronic backend kind is buildable and configurable without a Core
  change, as ADR 0009 predicted.
- The repository carries one optional experiment target and a test-support
  fixture. Neither is a Core or production dependency.
- The ADR 0005 extraction trigger stays deferred, now with concrete evidence
  rather than assumption.
- No wire, manifest-shape, protocol-major, or persisted-identity contract
  changes.

## Reconsideration triggers

Reconsider production support, or Positronic adapter extraction, when a Letta
backend is shipped as a supported kind, when live-server evidence changes the
cancellation or health mapping, or when a second shipped backend makes the
shared adapter boundary concrete. Reconsider the Timeline projection if Letta
gains a durable client-supplied conversation identifier or a documented
conversation metadata field.

## Links

- [#246 — evaluate Letta as the first non-Positronic Ascendant backend](https://github.com/phynics/Gnostic/issues/246)
- [#242 — unify backend composition](https://github.com/phynics/Gnostic/issues/242)
- [#245 — prove mixed Ascendant configurations on one Node](https://github.com/phynics/Gnostic/issues/245)
- [ADR 0002 — Gnostic identity versus backend state](0002-gnostic-identity-vs-backend-state.md)
- [ADR 0005 — Core PositronicKit dependency boundary](0005-core-positronic-dependency-boundary.md)
- [ADR 0007 — Timeline-bound backend session contract disposition](0007-timeline-bound-backend-session-contract-disposition.md)
- [ADR 0009 — Multi-configuration Ascendant hosting on one Node](0009-multi-configuration-ascendant-hosting.md)
