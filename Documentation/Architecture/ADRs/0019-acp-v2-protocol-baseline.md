# ADR 0019 — ACP v2 as Gnostic's protocol baseline

## Status

**Accepted** (2026-10-15), with one open owner question:
[T1, the transition for v1-only peers](#t1--peers-that-speak-only-acp-v1).
Owning issue: [GNO-ACPF-018 #633](https://github.com/phynics/Gnostic/issues/633),
under [Epic #602](https://github.com/phynics/Gnostic/issues/602). Checked by the
[Epic #140](https://github.com/phynics/Gnostic/issues/140) and
[RESET-001 #145](https://github.com/phynics/Gnostic/issues/145) documentation
gates.

The owner's direction is "assume ACP v2". The decision was first recorded as
question Q16 inside
[ADR 0018](0018-gnostic-primitives-after-the-acp-pivot.md). An independent
review then advised a separate record, because it reverses ADR 0018's
convert-at-the-edge answer (Q5), replaces ADR 0011's SDK selection, and has
triggers of its own.

This record amends:

- [ADR 0011](0011-external-acp-backends.md) and `ACP-SDK-Evaluation.md`: the
  v1-only `aptove/swift-sdk` is replaced by a Gnostic-owned ACP v2 wire model
  (section 8);
- [ADR 0017](0017-acp-first-host-and-harness-agent.md): wherever it names
  `session/load`, read `session/resume`, optionally with `replayFrom`;
- [ADR 0018](0018-gnostic-primitives-after-the-acp-pivot.md): §4's payloads
  are ACP v2 as specified here, and Q5's version tag serves a future major.

It changes no code by itself. Delivery: #572 (wire model), #629 (Turn
envelope), #605 (record), #606 (MCP transports), #631 (Runtime probes), and
#632 (replay scenarios).

## Context

Facts on agent-client-protocol `main`, as of 2026-10-15:

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
    -32800). After insertion it is `session/cancel`.
- **The session baseline** (`v2/required-session-methods.mdx`): an agent that
  advertises `session` supports `session/list`, `session/resume`, and
  `session/close`. `session/load` is gone; `session/resume` takes an optional
  `replayFrom` cursor (`v2/session-resume-replay.mdx`). `session.mcp`
  advertises MCP transports, and `session.additionalDirectories` is optional.
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
  `session/prompt` for an admitted Turn only when the Session's last reported
  state is `idle`, or when no state has been reported since the Session started
  or resumed. If the Runtime is `running` work it started itself, the admitted
  Turn waits in Gnostic's queue. Gnostic does not rely on queueing inside the
  Runtime, because the RFD leaves queueing unspecified.
- **Insertion.** A Turn is *inserted* when `session/prompt` returns a
  `messageId`. Gnostic records it as a strong Runtime ref. An error response
  means not inserted: the Turn fails with that error's code and is never resent
  automatically.
- **At most once.** Each admitted Turn sends at most one `session/prompt`. If
  the response is lost (connection or Node failure), Gnostic resumes the
  Session with replay. It then looks for the user message it sent, identified by
  the prompt digest (ADR 0018 Q13), among the messages after the last known
  `messageId`.
  - If found, Gnostic binds that `messageId` and continues.
  - If not found, the Turn ends `insertionUnknown` and is never resent.

  A `clientTurnID` retry returns the recorded outcome. A Gnostic Turn is
  *admitted* once and *inserted* at most once.
- **Completion.** The first `idle` `state_update` after insertion ends the
  Turn. `stopReason` maps to the terminal outcome. An omitted stop reason maps
  to `endedUnspecified`, which is neither success nor failure.
  `requires_action` keeps the Turn open.
- **Attribution.** Updates between insertion and the idle that ends the Turn
  belong to that Turn. All other updates belong to the Timeline's open span,
  outside any Turn (section 3).

### 3. Updates outside a Turn

- Gnostic streams updates outside a Turn live to the Timeline's subscribers, on
  a Timeline-scoped stream next to the Turn stream.
- They are persisted only in the opt-in Timeline record (ADR 0018 Q14). With
  the record off, they are live-only and cannot be replayed. Gnostic says so to
  a reconnecting subscriber instead of implying that nothing happened.
- They never reopen or extend a finished Turn.
- History that `session/resume` replays arrives before the resume response, so
  Gnostic treats it as replay. It reconciles that history with the record by
  `messageId` and `toolCallId`, and never records it a second time.

### 4. Permission requests

- **Inside a Turn,** a permission request goes to the Turn's client, as in
  ADR 0018 §4.
- **Outside a Turn,** it goes to the Timeline's subscribed clients.
- **No answer.** If no client answers within a Node-configured bound, or none
  is subscribed, Gnostic replies with the cancelled outcome and records the
  request as `unavailable`. A Runtime never waits forever in `requires_action`
  on Gnostic.
- **Shape.** Gnostic passes the v2 `title`, `subject`, and option IDs through
  unchanged.

### 5. Cancellation

A Gnostic Turn cancel maps to `$/cancel_request` before insertion, when the
Runtime supports it. Otherwise Gnostic waits for insertion and then cancels
with `session/cancel`. After insertion it is always `session/cancel`. The Turn
then ends on the next `idle`.

### 6. MCP transports and roots

- **MCP transports.** The gateway (#606) picks its transport from what the
  Runtime advertises in `session.mcp`: MCP-over-ACP, then HTTP, then stdio. It
  uses the v2 `McpServer` form with its `type` discriminator.
- **Roots.** Workspaces beyond the primary root become roots only when the
  Runtime advertises `session.additionalDirectories`. Otherwise they are served
  as tools, when they have a tool form, or reported `unsupported` as roots.
- **Resume.** `session/resume` resends `mcpServers` and roots.

### 7. The session baseline

A Runtime instance (#631) that advertises `session` gets resumable spans. One
that does not is still usable: every continuation becomes a seeded span
(ADR 0018 §3), and its capabilities say so.

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

## Open question

### T1 — Peers that speak only ACP v1

Today some Runtimes, and possibly every editor, speak only v1. A v2-only
Gnostic cannot reach them. The options:

- **(a) v2 only.** v1-only peers are unsupported until they ship v2, and any
  bridge lives outside Gnostic. Real-Runtime evidence (#632) and the 0.5.0
  release wait for v2 peers.
- **(b) A removable v1 edge adapter.** One isolated target translates a v1
  peer to the v2 model *at the connection edge*. It is a Runtime-side adapter
  for `acp-client` and an editor-side adapter for `gnostic acp`. The core, the
  envelope, and the record never see v1. Each v1 peer the adapter serves is
  listed with a removal condition: that peer ships v2.

*Recommendation:* **(b)**. It keeps the v2 model pure, which is what the
"assume v2" direction protects, and it lets Gnostic run against today's peers.
The adapter is deleted peer by peer. Until the owner decides, development
targets the v2 model, and T1 gates only real-Runtime acceptance and the 0.5.0
release.

## Invariant

- Gnostic's core, envelope, record, and gateway use only the ACP v2 model.
- Each admitted Turn is inserted at most once.
- A Turn ends only on an `idle` after its insertion. Updates outside a Turn
  never change a Turn's outcome.
- A permission request always gets an answer from Gnostic, never an indefinite
  wait.

## Rejected alternatives

- **Negotiate v1 and v2 in the core, as T3 Code does.** The two prompt
  lifecycles differ: v1 holds the prompt open for the whole turn, and v2
  returns at insertion. Carrying both through the envelope, ledger, and record
  doubles the Turn semantics. T1 (b) keeps any v1 support at the edge instead.
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
- **#632's real-Runtime acceptance and the 0.5.0 release depend on T1.**
- **#631 probes report v1-only Runtimes explicitly.** Under (a) they are
  unsupported, and under (b) they are served by the edge adapter.
- **The Turn ledger gains** the `insertionUnknown` and `endedUnspecified`
  outcomes.

## Fitness check

- `make docs-check` validates this record.
- The delivering issues add tests: no v1 type outside the edge adapter target
  (if T1 (b) is chosen); one `session/prompt` per admitted Turn under a dropped
  response (#632 scenario); and Turn end only on `idle` after insertion.

## Reconsideration triggers

- The v2 RFDs change incompatibly, or ACP v2 is declared stable.
- An important peer stays on v1 with no v2 plan (revisit T1).
- ACP specifies queueing, a durable client turn identifier, or a lost-response
  recovery rule for `session/prompt`.

## Links

- [#633 — this decision](https://github.com/phynics/Gnostic/issues/633)
- [ADR 0018 — Gnostic primitives after the ACP pivot](0018-gnostic-primitives-after-the-acp-pivot.md)
- [ADR 0017 — ACP-first host and the Gnostic harness agent](0017-acp-first-host-and-harness-agent.md)
- [ADR 0011 — External ACP agents as Ascendant backends](0011-external-acp-backends.md)
- [ACP RFDs](https://agentclientprotocol.com/rfds/about)
- [#630 — t3code design reference](https://github.com/phynics/Gnostic/issues/630)
- [Epic #140](https://github.com/phynics/Gnostic/issues/140)
- [RESET-001 #145](https://github.com/phynics/Gnostic/issues/145)
