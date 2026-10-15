# ADR 0019 — ACP v2 as Gnostic's protocol baseline

## Status

> **Amended (2026-10-15):** [ADR 0020](0020-timeline-first-primitives.md)
> delivers no Workspace as a root under its first placement strategy, and
> reads "the Agent switches" (§7, T2) as "the Timeline switches Runtime
> instance". This record's protocol decisions are unchanged.

**Accepted** (2026-10-15). The owner also decided its three questions the same
day; see [Owner decisions](#owner-decisions). In short: **no ACP v1 support at
all** (T1), 0.5.0 ships ACP as an opt-in **v2 preview** (T2), and an unanswered
permission request is answered with error **-32800** (T3).
Owning issue: [GNO-ACPF-018 #633](https://github.com/phynics/Gnostic/issues/633),
under [Epic #602](https://github.com/phynics/Gnostic/issues/602). Checked by the
[Epic #140](https://github.com/phynics/Gnostic/issues/140) and
[RESET-001 #145](https://github.com/phynics/Gnostic/issues/145) documentation
gates.

The owner's direction is "assume ACP v2". The decision was first recorded as
question Q16 inside
[ADR 0018](0018-gnostic-primitives-after-the-acp-pivot.md). An independent
review then advised a separate record. It narrows ADR 0018's
convert-at-the-edge answer (Q5) to "one v2 model, and no v1 anywhere" (T1),
it replaces ADR 0011's SDK selection, and it has triggers of its own.

This record amends:

- [ADR 0011](0011-external-acp-backends.md) and `ACP-SDK-Evaluation.md`: the
  v1-only `aptove/swift-sdk` is replaced by a Gnostic-owned ACP v2 wire model
  (section 8);
- [ADR 0017](0017-acp-first-host-and-harness-agent.md): wherever it names
  `session/load`, read `session/resume`, optionally with `replayFrom`;
- [ADR 0018](0018-gnostic-primitives-after-the-acp-pivot.md): §4's payloads
  are ACP v2 as specified here. Q5's version tag records the v2 revision now,
  and a future major later.

It changes no code by itself. Delivery: #572 (wire model), #629 (Turn
envelope), #605 (record), #606 (MCP transports), #631 (Runtime probes), and
#632 (replay scenarios).

## Context

Facts on agent-client-protocol `main`, as of 2026-10-15. These come from the
v2 RFDs and the draft v2 protocol pages (`docs/protocol/v2/`, including
`cancellation` and `prompt-lifecycle`):

- **The v2 RFDs are in the Active stage.** The v2 overview asks that v2 ship
  opt-in, off by default, and clearly labeled unstable, and not run in
  production without feature flags before a more stable release. It also
  expects SDKs to target v2 while falling back to v1 for v1 peers.
- **The v2 prompt lifecycle differs from v1** (`v2/prompt.mdx`):
  - `session/prompt` returns when the user message is *inserted*, with an
    agent-generated `messageId`. A JSON-RPC error on it always means the
    message was not inserted.
  - Foreground work is reported by `state_update`: `running`, `idle` with an
    optional `stopReason` (`error` for a failure after insertion), or
    `requires_action`. An agent that cannot tell why work stopped may omit the
    stop reason.
  - An agent may send session updates at any time, not only during a prompt.
  - Cancellation before insertion is `$/cancel_request` (answered with
    -32800). After insertion it is `session/cancel`. `$/cancel_request` has no
    capability marker, and a receiver may ignore it.
  - **A lost `session/prompt` response is ambiguous.** Replay cannot reliably
    tie a message to an uncertain submission. Clients must not guess from
    content or order, and must not assume a retry cannot create a second
    submission.
  - The user-message update and the prompt response describe one insertion,
    and **clients must tolerate the update arriving before or after the
    response**.
  - Synchronizing the current state on resume is an unresolved follow-up.
- **The session baseline** (`v2/required-session-methods.mdx`): an agent that
  advertises `session` supports `session/list`, `session/resume`, and
  `session/close`. `session/load` is gone; `session/resume` takes an optional
  `replayFrom` cursor (`v2/session-resume-replay.mdx`). A full replay should
  *rebuild* message history rather than merge it by ID, because agent and
  thought message IDs need not be stable across replays. User-message IDs are
  stable for retained messages. `session.mcp` advertises MCP transports, and
  `session.additionalDirectories` is optional. An agent that omits
  `capabilities.session` offers no `session/new` or `session/prompt`. It is
  not a conversational agent.
- **Permission outcomes.** `permission-requests.mdx` defines no new outcomes.
  The `cancelled` outcome is what a client answers when it sends
  `session/cancel` (`protocol/v2/cancellation`). An executing party may also
  cancel a request internally and answer it with error -32800.
- **Updates.**
  - Messages are upserts and chunks keyed by `messageId`. A whole-message
    update replaces what was accumulated.
  - Tool calls are `tool_call_update` upserts plus `tool_call_content_chunk`.
  - Plans are `plan_update`, and diffs are structured file states.
  - Terminal output is display-only and owned by the agent.
  - Permission requests carry a `title` and an optional `subject`.
  - An unknown enum value with a safe fallback is not an error, and `_`
    prefixes extensions.
- **Peers.** T3 Code (#630) reports that it uses the v2 preview where a
  Registry agent supports it, and negotiates v1 for agents that have not
  migrated, such as Pi. Which Runtimes and editors speak v2 today (Claude Agent,
  Codex, and opencode adapters; Zed and other editors) is **unverified**.
- **The pinned SDK is v1-only.** Gnostic pins `aptove/swift-sdk` 0.1.16,
  where `ProtocolVersion.current` is 1. The repository was last pushed
  2026-04-25.

## Decision

### 1. ACP v2 is Gnostic's protocol model

Gnostic's ACP wire model, Turn payloads, Timeline record, and gateway use ACP v2
shapes. Gnostic implements a **recorded revision** of the v2 schema. The Turn
envelope's ACP version tag carries `2` plus that revision. While the v2 RFDs are
not stable, Gnostic labels its ACP support as **v2 preview**. An incompatible
upstream change is a Gnostic change with its own issue, never a silent
reinterpretation.

### 2. Admission, insertion, and completion

- **Serialization.** Gnostic admits Turns per Timeline, as today. It sends
  `session/prompt` for an admitted Turn only after it has observed `idle` for
  the Session. Right after a resume, the current state is unknown (the RFD
  leaves resume-state synchronization open). Gnostic then waits for a reported
  state, or for a Node-configured quiet period with no updates, and records
  that it assumed `idle`. If the Runtime is `running` work it started itself,
  the admitted Turn waits in Gnostic's queue. Gnostic does not rely on queueing
  inside the Runtime, which the RFD leaves unspecified.
- **Pending attribution.** From the moment Gnostic sends `session/prompt`, the
  Turn is *pending insertion*, and every update belongs to it. Only one Turn
  per Session can be pending, so the user-message update may arrive before or
  after the response, as the RFD requires clients to tolerate.
  - A successful response binds the Turn to its `messageId`. Gnostic records it
    as a strong Runtime ref and reconciles it with an already received
    user-message update instead of creating a second message.
  - An error response means not inserted. The Turn fails with that error's
    code, is never resent automatically, and its pending updates move to the
    open span.
- **At most once, and no guessing.** Each admitted Turn sends at most one
  `session/prompt`. If the response is lost (connection or Node failure), the
  outcome is ambiguous, and the RFD forbids guessing from content or order.
  The Turn ends **`insertionUnknown`**. Gnostic never resends it and never
  binds a replayed message to it. A `clientTurnID` retry returns the recorded
  outcome. A Gnostic Turn is *admitted* once and *inserted* at most once.
- **Completion.** The Turn ends at the first `idle` reported after the prompt
  was sent, once insertion is confirmed. If `idle` arrives before the response,
  the Turn ends when the success response arrives. `stopReason` maps to the
  terminal outcome. An omitted stop reason maps to `endedUnspecified`, which is
  neither success nor failure. `requires_action` keeps the Turn open.
- **Attribution after completion.** Every update that arrives while no Turn is
  pending or open belongs to the Timeline's open span, outside any Turn
  (section 3).

### 3. Updates outside a Turn

- Gnostic streams updates outside a Turn live to the Timeline's subscribers, on
  a Timeline-scoped stream next to the Turn stream.
- They are persisted only in the opt-in Timeline record (ADR 0018 Q14). With
  the record off, they are live-only and cannot be replayed. Gnostic says so to
  a reconnecting subscriber instead of implying that nothing happened.
- They never reopen or extend a finished Turn.
- History that `session/resume` replays arrives before the resume response, so
  Gnostic treats it as replay, never as new activity. A full replay is stored
  as a **replay snapshot** of the span's Runtime-side history, which the RFD
  says to rebuild rather than merge by ID. It is never merged into recorded
  Turns. Only user messages are matched, by their stable `messageId`, to link
  the snapshot to recorded Turns.

### 4. Permission requests

- **Inside a Turn,** a permission request goes to the Turn's client, as in
  ADR 0018 §4.
- **Outside a Turn,** it goes to the Timeline's subscribed clients.
- **No answer.** If no client answers within a Node-configured bound, or none
  is subscribed, Gnostic answers the request without waiting forever, and
  records it as `unavailable`, never as a denial. On the wire it answers with
  error **-32800**, an internal cancellation of that one request, which
  `protocol/v2/cancellation` allows the executing party to send (T3). The Turn
  continues, and the Runtime decides how to proceed without a decision.
  Gnostic does not use `cancelled` here, because v2 ties that outcome to
  `session/cancel`, and it does not select a reject option, because that would
  invent a denial.
- **Shape.** Gnostic passes the v2 `title`, `subject`, and option IDs through
  unchanged.

### 5. Cancellation

Gnostic cannot know in advance whether a Runtime honours `$/cancel_request`,
or whether insertion has already happened. So a Gnostic Turn cancel works like
this:

- **While pending insertion,** send `$/cancel_request` for the prompt.
  - If the response is error -32800, the Turn ends `cancelled`, not inserted.
  - If the response is a success (inserted anyway), follow it with
    `session/cancel`.
- **After insertion,** send `session/cancel`, and answer any pending permission
  requests with `cancelled`, as the cancellation page requires.

In both cases the Turn ends on the next `idle`.

### 6. MCP transports and roots

- **MCP transports.** The gateway (#606) picks its transport from what the
  Runtime advertises in `session.mcp`: MCP-over-ACP, then HTTP, then stdio.
  MCP-over-ACP is a separate draft RFD, not part of the v2 set. Gnostic uses it
  only when advertised. It
  uses the v2 `McpServer` form with its `type` discriminator.
- **Roots.** Workspaces beyond the primary root become roots only when the
  Runtime advertises `session.additionalDirectories`. Otherwise they are served
  as tools, when they have a tool form, or reported `unsupported` as roots.
- **Resume.** `session/resume` resends `mcpServers` and roots.

### 7. The session baseline

A Runtime instance (#631) must advertise `capabilities.session`. Without it, a
v2 agent offers no `session/new` or `session/prompt`, so it is not a
conversational Runtime, and Gnostic reports it unsupported. With it, resume is
baseline. A span is seeded (ADR 0018 §3) only when a resume fails or the Agent
switches.

### 8. A Gnostic-owned v2 wire model

One ACP v2 wire model, owned by Gnostic and generated from or checked against
the ACP JSON schema at the recorded revision (#572), replaces
`aptove/swift-sdk`. It lives in a PositronicKit-free target. The `gnostic acp`
frontend, the `acp-client` backend, and the harness agents (ADR 0017) all
depend on it, which the firewall allows (ADR 0017 §7).

The model preserves unknown enum values that have a fallback, and `_`
extensions. Removing the SDK is a dependency change with its own resolution
evidence.

### 9. Scope

The in-process `positronic` and `letta` backend kinds are not ACP and are
outside this record until #611 removes them.

## Owner decisions

Decided by the owner on 2026-10-15.

| # | Question | Decision | Rejected options |
| --- | --- | --- | --- |
| T1 | Peers that speak only ACP v1 | **No v1 support at all.** Gnostic neither negotiates nor translates v1, in the core or at an edge adapter. A v1-only Runtime or editor is unsupported until it ships v2. Any bridge someone builds lives outside Gnostic and is not supported by it. | A removable v1 edge adapter (it would have to synthesize insertion and a weak `messageId`, and it weakens at-most-once for v1 peers). |
| T2 | Releasing on a v2 preview | **0.5.0 ships ACP as an opt-in *v2 preview***, behind an explicit flag. The compatibility declaration states that the ACP surface is outside the 0.5.x stability promise. The Gnostic surfaces (Agent, Timeline, Workspace, the Turn envelope) stay inside it. | Holding 0.5.0 until ACP v2 is stable; shipping stable on a v1 adapter. |
| T3 | Unanswered permission requests | **Answer with error -32800**, an internal cancellation of that request, and record `unavailable` (§4). | Selecting a reject option (a denial on the user's behalf); `cancelled` plus `session/cancel` (it stops the Turn). |

**What T1 means in practice.** Some Runtimes, and possibly every editor, speak
only v1 today. Until they ship v2, Gnostic cannot run them, and `gnostic acp`
cannot serve them. Real-Runtime evidence (#632) and the 0.5.0 release
candidate need at least one v2-preview Runtime and one v2-preview client. The
recorded transcripts in #632 and the fixture agent stand in for real peers in
`verify` until then.

## Invariant

- Gnostic contains no ACP v1 code path: not in the core, the envelope, the
  record, the gateway, or any edge (T1).
- Each admitted Turn is inserted at most once, and a lost prompt response is
  never resolved by guessing.
- A Turn ends only on an `idle` after its prompt was sent, once insertion is
  confirmed. Updates outside a Turn never change a Turn's outcome.
- A permission request always gets an answer from Gnostic, never an indefinite
  wait.

## Rejected alternatives

- **Negotiate v1 and v2 in the core, as T3 Code does.** The two prompt
  lifecycles differ: v1 holds the prompt open for the whole turn, and v2
  returns at insertion. Carrying both through the envelope, ledger, and record
  doubles the Turn semantics.
- **A removable v1 edge adapter.** It would keep the core v2-pure, but it would
  have to synthesize insertion points and weak `messageId`s, and it would weaken
  at-most-once for v1 peers. The owner chose no v1 support at all (T1).
- **Keep v1 as the model and convert to v2 later.** That builds every new
  surface (the envelope, record, gateway, and spans) on the shape that is being
  replaced, and v1 has no updates outside a prompt.
- **Wait for v2 to stabilize before building.** The pivot's new work is all
  ACP-shaped. Building on v1 now means building it twice.
- **Keep `aptove/swift-sdk` and extend it.** It is v1-only and has been
  inactive since 2026-04. Gnostic would own a fork either way.

## Consequences

- **#572 becomes a P1 prerequisite of #629.**
- **Gnostic's ACP support is labeled v2 preview** until the v2 RFDs complete.
  The compatibility declaration says so.
- **0.5.0 ships ACP as an opt-in v2 preview (T2).** The compatibility
  declaration excludes the ACP surface from the stability promise.
- **v1-only peers are unsupported (T1).** #631 probes report them as
  `unsupported (ACP v1)`. `gnostic acp` refuses a v1 client with a clear error.
  #632's real-Runtime acceptance, and the 0.5.0 release candidate, need
  v2-preview peers.
- **The Turn ledger gains** the `insertionUnknown` and `endedUnspecified`
  outcomes. A lost prompt response is visible to the user rather than silently
  retried.

## Fitness check

- `make docs-check` validates this record.
- The delivering issues add tests:
  - no ACP v1 type or method name anywhere in `Sources` (a fitness test);
  - a v1 `initialize` from a Runtime or client is rejected with a clear error;
  - one `session/prompt` per admitted Turn, and `insertionUnknown` under a
    dropped response (a #632 scenario);
  - correct attribution when the user-message update and `idle` arrive before
    the prompt response;
  - a success response after `$/cancel_request` followed by `session/cancel`.

## Reconsideration triggers

- The v2 RFDs change incompatibly, or ACP v2 is declared stable.
- An important peer stays on v1 with no v2 plan, or no v2-preview editor exists
  by the 0.5.0 release candidate (revisit T1).
- ACP specifies queueing, a client-generated correlation token for prompts
  (which would replace `insertionUnknown` with real recovery), or
  current-state synchronization on resume.

## Links

- [#633 — this decision](https://github.com/phynics/Gnostic/issues/633)
- [ADR 0018 — Gnostic primitives after the ACP pivot](0018-gnostic-primitives-after-the-acp-pivot.md)
- [ADR 0017 — ACP-first host and the Gnostic harness agent](0017-acp-first-host-and-harness-agent.md)
- [ADR 0011 — External ACP agents as Ascendant backends](0011-external-acp-backends.md)
- [ACP RFDs](https://agentclientprotocol.com/rfds/about)
- [#630 — t3code design reference](https://github.com/phynics/Gnostic/issues/630)
- [Epic #140](https://github.com/phynics/Gnostic/issues/140)
- [RESET-001 #145](https://github.com/phynics/Gnostic/issues/145)
