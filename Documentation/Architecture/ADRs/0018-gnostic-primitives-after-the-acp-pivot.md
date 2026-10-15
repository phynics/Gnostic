# ADR 0018 — Gnostic primitives after the ACP pivot: Agent, Runtime, spans, and ACP-native Turns

## Status

> **Proposed amendment (2026-10-15):** [ADR 0020](0020-timeline-first-primitives.md)
> would supersede §1 and §2 (no Agent primitive), §6 (Workspaces delivered
> through the gateway with a scratch Project first), and §7 (no Gnostic
> capabilities), and would amend §3, §4, and §5.

**Accepted** (2026-10-15). The owner accepted the recommended answer to every
open question (Q1–Q14), and then made two further decisions the same day:
a **Runtime instance** layer (Q15, from design reference
[#630](https://github.com/phynics/Gnostic/issues/630)) and **ACP v2 as the
protocol baseline** (Q16). On independent-review advice, Q16 is recorded in its
own decision, [ADR 0019](0019-acp-v2-protocol-baseline.md). See [Owner decisions](#owner-decisions). Owning issue:
[GNO-ACPF-014 #626](https://github.com/phynics/Gnostic/issues/626), under
[Epic #602](https://github.com/phynics/Gnostic/issues/602). Builds on
[ADR 0017](0017-acp-first-host-and-harness-agent.md). Checked by the
[Epic #140](https://github.com/phynics/Gnostic/issues/140) and
[RESET-001 #145](https://github.com/phynics/Gnostic/issues/145) documentation
gates.

This record decides how Gnostic's primitives change now that every Ascendant
Backend is an ACP agent. One Gnostic-owned primitive, the **Agent**, replaces
the Ascendant, and the ACP program an Agent runs on becomes a value, its
**Runtime**.

It is a direction decision. It changes no code, wire contract, or manifest
shape by itself. Delivery is tracked by
[#629](https://github.com/phynics/Gnostic/issues/629) (Turn envelope, rename,
new `protocolMajor`) and by the #602 children named in each section. Until #629
lands, code, wire operations, and the manifest still say "Ascendant".

`CONTEXT.md` is revised with this record. It amends:

- [ADR 0001](0001-axoloty-native-multi-backend-host.md): "Axoloty-native"
  narrows to discovery and routing (§5);
- [ADR 0011](0011-external-acp-backends.md): the Ascendant Backend becomes the
  Runtime (§1);
- [ADR 0017](0017-acp-first-host-and-harness-agent.md) in several places:
  - §2: the Timeline record stores ACP payloads as received, not normalized
    updates (§4), and a Timeline continues through `session/resume` ([ADR 0019](0019-acp-v2-protocol-baseline.md));
  - §3 and its Workspace invariant: root delivery is an owner-decided exception
    (§6, Q12);
  - §4: a child Timeline records its operating Agent;
  - §5 and §6: the Agent definition and the Regime merge (§1).

## Context

ADR 0017 made ACP the backend boundary, but kept the primitives from the
PositronicKit era. Several of them no longer describe what Gnostic does:

- **The Ascendant still models a Positronic agent.** `CONTEXT.md` defines it as
  "a stable Gnostic logical agent identity". Ascendant diagnostics carry a
  `privateTimelineID`, and the manifest gives every Ascendant a
  `defaultTimelineID`. An ACP agent has no Gnostic-managed memory, and ADR 0017
  moves continuity into the Timeline record. Meanwhile the ACP frontend already
  calls an Ascendant a *profile* (`gnostic acp profiles`, `profileFingerprint`,
  `ACPProfileCache`).
- **The Ascendant definition and the Regime are nearly the same thing.**
  ADR 0017 defines the Ascendant definition as launch, instructions, session
  configuration, permission policy, and default Workspaces. It defines the
  Regime as agent, session configuration, outer modules, and policies.
- **A Timeline has one operator.** `Timeline.operatingAscendantID` is singular.
  Seeding (#613), delegation (#608), and switching agents make "operated by" a
  property of a span of a Timeline, not of the whole Timeline.
- **A Turn is converted twice and loses content.** `AscendantBackendTurnRequest.message`
  is a `String`, and the advertised capability is
  `me.atkn.gnostic.capability.turn.text`. `AscendantTurnUpdateKind` has eight
  kinds (assistant text and snapshot, tool call, tool state, permission state,
  completion, cancellation, error), plus separate tool and permission status
  vocabularies. ACP has typed content
  blocks (text, image, audio, resource, resource link) and session updates
  (message and thought chunks, tool calls with content and diffs, plans, usage,
  session information, and others). An ACP-to-ACP Turn through Gnostic is
  converted from ACP to Gnostic at the backend, and back to ACP at the frontend.
  Everything outside the twelve kinds is lost.
- **Axoloty's role is unstated.** ADR 0001 made Gnostic "Axoloty-native" when
  Axoloty carried discovery, Turns, and Workspace tool calls. ACP now carries the
  agent conversation, and MCP the tool calls. ACP has a draft streamable HTTP and
  WebSocket transport.
- **Workspaces have one delivery path.** ADR 0017 §3 serves every Workspace
  through the gateway as MCP tools. ACP also defines session roots: `cwd`, and
  `additionalDirectories` (an optional capability), which an agent's own file
  and shell tools use directly. Serving a local directory as gateway tools duplicates the
  agent's native tools and is worse at the same job.

## Decision

### 1. One configured primitive, the Agent, with a Runtime as its value

Two concepts remain after the pivot, but only one needs identity.

- **Agent (Gnostic-owned primitive).** A named, advertised, addressable
  configuration. It holds:
  - its **Runtime**;
  - instructions;
  - session configuration options (model, effort, and inner-module settings);
  - permission policy;
  - outer modules;
  - default Workspace attachments.

  Clients discover it on the network and address Turns to it, and Regimes are
  compared across it. Its UUID is Gnostic identity. The Agent definition **is**
  its Regime, so there is one configuration object, not two. Changing the
  Runtime makes a different Regime, and therefore a different Agent.
- **Runtime (kind, a value).** The kind of ACP harness: Claude Agent, Codex,
  opencode, or a harness built in this repository. A Runtime kind is identified
  by its ACP registry identifier, or as `local-command` (Q10).
- **Runtime instance (Node-scoped, Gnostic-owned; Q15).** One configured install
  of a Runtime kind on one Node. It owns:
  - its install and pinned version, or its executable override;
  - its arguments, environment, and secrets;
  - its authentication state;
  - its advertised catalog (models and session config options);
  - its processes.

  Every Session runs on exactly one instance, and work is routed by instance.
  Instances are mutable (updates, catalog, auth), so each span and each Run
  record captures the instance ID, its version, and its launch fingerprint when
  the span starts. A later change to the instance never rewrites what ran.
  Two instances of the same kind never share mutable state or credentials, and
  two Agents that reference one instance share one account. An instance has a
  Node-scoped ID. When it has no registry ID, its kind is fingerprinted over
  the command, the arguments, and the *names* of the environment variables,
  never their values or any secret. Gnostic records the name and version the
  program reports. Instance management is delivered by #631.

  An Agent references one Runtime instance. One instance can back many Agents
  (a reviewer and a researcher on one Claude Agent login). A cross-Runtime
  comparison (#614) compares two Agents whose definitions differ only in their
  Runtime instance. The Run record names both Agents and the one field that
  differs.
- **Session (external state).** One ACP session of a Runtime. It serves one or
  more spans of one Timeline (section 3); a `resumed` span reuses an earlier
  Session. It is backend-private state, as in ADR 0011.
  Gnostic records it but never treats it as identity.

An Agent has **no memory and no Timelines of its own**:

- the private Timeline and the per-Agent default Timeline are retired (Q2). A
  client or the frontend creates a Timeline on first use;
- continuity belongs to Timelines (ADR 0017 §2).

### 2. "Ascendant" is retired in favour of "Agent"

The term Ascendant existed so that Gnostic identity would not be confused with
PositronicKit's `AgentInstance` (`CONTEXT.md`, "Bounded legacy Agent
terminology"). ADR 0017 puts PositronicKit behind a firewall, inside the harness
agent, so that reason is gone. What remains is a configured agent in the sense
most agent tools use (a name, instructions, a model, tools).

- Gnostic-owned identity, wire operations, the manifest, and the CLI use
  **Agent**. The rename lands with the `protocolMajor` change in section 4, so
  0.5.0 breaks its wire contract once, not twice.
- In Gnostic's vocabulary, the ACP program is always the **Runtime**. "ACP
  agent" is used only when talking about the protocol's roles. This keeps the
  one collision (ACP calls the program "the Agent") out of Gnostic's own terms.
- The ACP frontend's "profiles" become Agents.
- **Code naming rule.** Gnostic is itself an ACP agent to editors (`gnostic acp`)
  while it routes Turns to Gnostic Agents. In code:
  - types for that protocol role keep the ACP SDK's names, or carry an `ACP`
    prefix (for example `ACPAgentConnection`);
  - Gnostic-owned types use `GnosticAgent…` wherever the bare name `Agent` would
    be ambiguous.

The bounded legacy Agent rule is replaced by these definitions.

### 3. A Timeline is a sequence of spans

A **span** is the stretch of a Timeline served by one Session of one Agent.
Each span records:

- its Agent;
- its Runtime instance and Session (a new Session, or a reused one);
- the first and last Turn;
- how it began: `new`, `resumed` (through `session/resume`, with or without
  history replay from a `replayFrom` cursor), `seeded` (with its strategy and
  what was lost), or `forked`.

A Timeline has at most one open span at a time.

- The Timeline's **current operator** is the Agent of its open span. It
  replaces the stored `operatingAscendantID`.
- A Turn addressed to a Timeline runs in its open span. A Turn never names a
  different Agent implicitly.
- Switching a Timeline to another Agent is an **explicit Timeline operation**
  (Q3). It closes the open span and opens a new one, usually `seeded`, so a
  lossy seeding step never happens by accident.
- Parallel work is modeled as child Timelines, never as concurrent spans (Q4).
- Lineage stays on the Timeline (ADR 0017 §4). A child Timeline links to its
  parent Timeline and the spawning Turn, not to a span.
- The Timeline record (#605) stores spans as its structure.

### 4. Turn payloads are ACP-native

A Gnostic Turn is a Gnostic **envelope** around ACP **payloads**.

- **The envelope is Gnostic-owned.** It holds:
  - the Timeline and the addressed Agent;
  - `clientTurnID`, admission, and idempotent replay (ADR 0006, ADR 0014);
  - the sequence number;
  - the terminal outcome and failure code;
  - `protocolMajor`.
- **The payload is ACP.**
  - The request carries ACP prompt content blocks.
  - The update stream carries ACP session update objects.
  - Permission requests carry ACP permission options.

  These travel verbatim, tagged with the ACP protocol version, and are never
  reduced to a Gnostic taxonomy.
- **Protocol baseline.** Payloads are ACP v2, as defined by [ADR 0019](0019-acp-v2-protocol-baseline.md). That record
  maps the Turn onto the v2 prompt lifecycle: insertion, the idle
  `state_update`, updates outside a Turn, permission requests without a Turn,
  and cancellation. It also settles how peers that still speak v1 are handled.
- **Gnostic interprets only what it needs:**
  - the terminal outcome ([ADR 0019](0019-acp-v2-protocol-baseline.md));
  - the `messageId` of the inserted prompt, recorded as a strong Runtime ref;
  - tool-call identifiers and permission subjects, for permission correlation;
  - usage numbers, for metering;
  - assistant messages, only to build the assistant-text snapshot that the Turn
    event log's compaction keeps (ADR 0014). The snapshot applies whole-message
    upserts and appends chunks per `messageId`.

  It passes the rest through. Update kinds it does not know are forwarded and
  recorded unchanged, never rejected. This is the forward-compatibility rule.
- **Permission is a request and reply, not an update.** ACP's
  `session/request_permission` expects an answer. The envelope carries it as a
  correlated permission request to the Turn's client, holding the ACP v2
  request (title, optional subject, options), and a correlated reply.
  [ADR 0019](0019-acp-v2-protocol-baseline.md) covers permission requests that arrive outside a Turn.
  - This reuses the existing permission correlation (ADR 0011 mediation;
    `AscendantPermissionCoordinator`).
  - A timeout, a lost connection, or a Node failure answers the Runtime with a
    cancelled outcome. Gnostic records it as `unavailable`, not as a denial.
  - Replaying a Turn returns the recorded decision and never prompts again.
- **Replay identity.** The `clientTurnID` conflict check hashes the canonical
  form of the prompt payload: JSON Canonicalization Scheme (RFC 8785) over the
  content blocks, plus the ACP version tag (Q13). Retries that differ only in
  key order therefore still match.
- **Size (Q6).** Content above a size threshold travels as an ACP resource link
  to a blob that Gnostic serves. Each Node advertises its threshold as a
  capability. A payload still over the Axoloty event budget or the journal bound
  is rejected with an explicit failure code, as oversize prompts already are. It
  is never truncated or dropped.
- **Payload-free diagnostics stay payload-free.** Diagnostics, metering, and the
  console read only envelope fields and usage numbers. They never read tool-call
  titles, `rawInput`, paths, or any content block.
- **For text-only consumers,** `GnosticClient` offers a projection helper (for
  example, assistant text only). The projection is a client convenience, not
  the wire format.
- **This changes the wire contract.** It needs a new `protocolMajor` (ADR 0003),
  delivered by #629 together with the rename (§2). It lands inside the 0.5.0
  line, before the stable surface is declared
  (decision D10 on #551). The eight-kind `AscendantTurnUpdateKind` taxonomy (with its status vocabularies) and
  the `turn.text` capability are retired at that major.

### 5. Axoloty is the discovery and routing fabric

Axoloty keeps four jobs:

- discovery and advertisement of Nodes, Agents, Timelines, and Workspaces;
- liveness;
- routing of Gnostic operations to the Node that owns the target;
- the cross-Node transport for the Turn envelope (section 4) and for remote
  Workspace calls behind the gateway.

Axoloty is **not** the agent protocol (ACP is), and **not** the tool protocol
(MCP is). Gnostic defines no new tool or conversation semantics on Axoloty. It
carries ACP and MCP payloads inside Gnostic envelopes. This narrows ADR 0001.
Axoloty stays the cross-Node fabric for 0.5.0; ACP over HTTP or WebSocket is a
reconsideration trigger, not a plan (Q7).
"Axoloty-native" now means Axoloty-native discovery and routing.

### 6. Workspaces are delivered as roots or as gateway tools

A Workspace states which delivery forms it supports:

- **Root:** a filesystem directory on the same host as the Runtime process.
  - The Timeline's primary root becomes the Session's `cwd`.
  - Other root Workspaces become `additionalDirectories`, when the Runtime
    advertises that capability.
  - The Runtime's own file and shell tools use them directly.
  - Gnostic never writes into a root to configure the Runtime.
- **Tools:** the Workspace's tools are served by the Gnostic gateway as MCP tools
  (ADR 0017 §3). This is the form for remote Workspaces and for capability
  Workspaces that are not filesystems.

**Root delivery bypasses Gnostic mediation, so it is opt-in (Q12).**
ADR 0017 makes it an invariant that every Workspace tool call crosses Gnostic's
effective-status and permission checks. A root breaks that invariant: the
Runtime's native tools reach the directory directly, and only the Runtime's own
permission prompts (forwarded through ACP) stand in the way. So:

- a Workspace is delivered as a root only when its attachment explicitly allows
  it;
- a Workspace that is `unavailable` or attached read-only is never delivered as
  a root;
- the Timeline record states which Workspaces were roots for each span.

**Effective status** is reported per delivery form: `available`, `unavailable`,
or `unsupported`. For example, a local repository can be `available` as a root
and `unsupported` as tools. Changing roots mid-session needs a Session resume
with the new root list, because ACP requires the client to resend the full list
on resume. When the Runtime does not support resume, changing roots opens a new
seeded span.

A remote filesystem Workspace is always delivered as tools, never as a root.
Mounting or syncing a remote directory is an operator concern outside Gnostic
(Q8).

When no root Workspace is attached, the Session's `cwd` is a Gnostic-owned
scratch directory for that Timeline under the state home. The record reports
it as such (Q9). A session never starts in an arbitrary directory.

### 7. Capabilities come from the Runtime

An Agent's advertised capabilities are derived from:

- the Runtime's ACP `initialize` result: session support, prompt content types,
  MCP transports, and session capabilities;
- what Gnostic itself adds: the gateway, the Timeline record, and delegation.

No capability is hand-declared per backend kind. This completes the derivation
that #566 started and #611 finishes.

## Invariant

- Gnostic identity is Node, Agent, Timeline, Workspace, and Turn. A Runtime or
  Session is never Gnostic identity, and losing one loses no Gnostic-owned
  state.
- An Agent holds configuration only. It owns no Timeline and no memory.
- A Timeline has at most one open span.
- Gnostic does not re-encode ACP payloads into its own taxonomy. It reads only
  the fields its envelope duties need.
- Axoloty carries no Gnostic-defined tool or conversation semantics.
- Every gateway-delivered Workspace call crosses Gnostic's effective-status and
  permission checks (ADR 0017). A root-delivered Workspace is the single,
  explicit exception: opt-in per attachment, never `unavailable` or read-only,
  and recorded per span (Q12, accepted).
- Diagnostics and metering never read Turn payload content.
- Turn payloads follow the protocol baseline in [ADR 0019](0019-acp-v2-protocol-baseline.md).
- Every Session runs on exactly one Runtime instance, and instances share no
  mutable state (Q15).

## Rejected alternatives

- **Keep the Runtime as a plain value with no instance (this record's
  first accepted text).** Accounts, credentials, installs, and processes are
  mutable state. Without an instance owning them, two Agents on one login
  either duplicate or silently share them (#630 §1).
- **Keep both Ascendant and Agent as primitives (Ascendant as a profile over an
  external Agent).** This was this record's first draft. It names two things
  where only one has identity, and it keeps a coined term whose reason
  (separation from PositronicKit's `AgentInstance`) is gone. The external program
  is a value, the Runtime.
- **Keep "Ascendant" and only redefine it.** This costs less churn now, but it
  keeps a term no other agent tool uses. The cheapest time to rename is the
  `protocolMajor` change that 0.5.0 already takes.
- **Keep the Ascendant as a logical agent with continuity.** Nothing behind the
  ACP boundary holds that continuity. The private and default Timelines would be
  empty promises, and continuity would exist twice: in the Ascendant and in the
  Timeline.
- **Keep the Agent definition and the Regime as separate objects.** They hold
  the same fields, and the CLI already resolves one into the other
  (`config regime show`). Two objects invite drift.
- **Extend the Gnostic update taxonomy, one ACP kind at a time.** Gnostic would
  mirror ACP forever, a step behind, and lose whatever it has not mirrored yet.
- **Carry raw ACP JSON-RPC frames.** Frames bind to one connection's request IDs
  and session IDs. Gnostic must re-address them across Nodes and replay them by
  `clientTurnID`. The envelope carries the payload objects, not the frames.
- **Replace Axoloty with ACP over HTTP or WebSocket.** That transport is a draft,
  and ACP has no discovery. Gnostic still needs to find Nodes, Agents, and
  Workspaces across machines. This becomes a reconsideration trigger instead.
- **Serve local directories only as gateway tools.** That duplicates every
  agent's native file and shell tools with weaker ones, and works against how
  agents sandbox their own execution.
- **Allow concurrent spans on one Timeline.** Two agent sessions writing one
  Timeline make its record ambiguous. Parallel work is modeled as child
  Timelines (forks or delegation).

## Dependency impact

None in this record. Delivery:

- #629 delivers the Turn envelope change, the rename, and the new
  `protocolMajor`. It lands **before** the Timeline record (#605), so the
  record stores ACP payloads from day one (Q11);
- the manifest renames Ascendants to Agents, and loses `defaultTimelineID` and
  `operatingAscendantID` in favour of spans (#607 and #613);
- the frontend (`gnostic acp`) and the ACP backend pass payloads through. Both
  can share one ACP model (#572).

- the ACP wire model and the replacement of the v1-only SDK are decided in
  [ADR 0019](0019-acp-v2-protocol-baseline.md) (#572);
- Runtime instance installs (#631) download ACP Registry distributions at run
  time. They are not package dependencies, but they need checksum
  verification and version pinning.

## Consequences


- **Ascendant becomes Agent everywhere Gnostic-owned:** wire operations,
  capabilities, manifest keys, CLI commands, diagnostics, and docs. Historical
  records keep the old term. The ACP frontend's profiles are Agents.
- **The Timeline record (#605) stores ACP payloads as received.** The record and
  the wire carry the same objects, so replay and inspection need no conversion.
  The record is a separate store from the Turn event log. The Turn event log
  keeps ADR 0014's guarantee: a prompt digest, never prompt content. Content at
  rest lives only in the opt-in record (Q14).
- **The gateway's scope narrows (#606)** to non-root Workspaces and the network
  tools.
- **Seeding and switching agents (#613) open new spans.** The record shows every
  boundary.
- **The console (#584) shows spans and each Agent's Runtime.** The payload-free
  rule is unchanged: ACP payloads are Turn bodies.
- **0.5.0 ships on the new `protocolMajor`,** with the rename and the envelope
  change together. It is a breaking change within the pre-1.0 line, declared in
  the 0.5.0 compatibility record.

## Glossary changes

- **Add:** Agent (as Gnostic-owned), Runtime, Session, Span, Current operator,
  Root (Workspace delivery), Turn envelope, Turn payload.
- **Redefine:**
  - Agent definition, as identical to the Agent's Regime;
  - Timeline, as a sequence of spans;
  - Workspace, with its delivery forms;
  - Effective status, per delivery form;
  - Turn, as envelope plus ACP payload;
  - Regime, as Agent configuration plus its Runtime.
- **Move into the harness agent's vocabulary:** Image, Image invocation, and
  Atlas.
- **Deprecate:**
  - Ascendant (use Agent);
  - Ascendant private Timeline and default Timeline;
  - `operatingAscendantID`;
  - the eight-kind Turn update taxonomy and its status vocabularies;
  - the `turn.text` capability;
  - Ascendant Backend as a pluggable contract (use Runtime);
  - the bounded legacy Agent rule;
  - Agent session (use Session).

## Owner decisions

The owner accepted the recommended answer to every question on 2026-10-15
(recorded on #626). Each answer is folded into the section named.

| # | Question | Decision | Where |
| --- | --- | --- | --- |
| Q1 | One primitive, and its name | **Agent**, with **Runtime** for the ACP program. "Ascendant" is retired, renamed together with the new `protocolMajor` (#629). | §1, §2 |
| Q2 | Default Timeline per Agent | **No.** A client or the frontend creates a Timeline on first use. | §1 |
| Q3 | Switching a Timeline's Agent | **An explicit Timeline operation.** A Turn never switches implicitly. | §3 |
| Q4 | Concurrent spans | **At most one open span.** Parallel work is child Timelines. | §3 |
| Q5 | ACP versions | **Tag the ACP version in the envelope.** Refined by [ADR 0019](0019-acp-v2-protocol-baseline.md). | §4 |
| Q6 | Payload size | **Resource links** above an advertised per-Node threshold. Reject what still exceeds the budget. | §4 |
| Q7 | Axoloty scope | **Axoloty stays the cross-Node fabric** for 0.5.0. ACP over HTTP is a trigger only. | §5 |
| Q8 | Remote roots | **Tools only.** Mounting is outside Gnostic. | §6 |
| Q9 | `cwd` with no root | **A per-Timeline scratch directory** under the state home, reported in the record. | §6 |
| Q10 | Runtime identity | **ACP registry ID**, else a launch fingerprint over the command, the arguments, and the environment variable names, with no secrets. Refined by Q15: this identifies the Runtime *kind*; instances have their own IDs. | §1 |
| Q11 | Delivery order | **Envelope first (#629), then the Timeline record (#605).** | Dependency impact |
| Q12 | Root delivery and mediation | **Allowed, opt-in per attachment.** Never for `unavailable` or read-only Workspaces; recorded per span. | §6, Invariant |
| Q13 | Replay hash basis | **RFC 8785 canonical JSON** of the prompt content blocks plus the ACP version tag. | §4 |
| Q14 | Content at rest | **The Turn event log stays digest-only.** Only the opt-in Timeline record stores ACP payload content. | Consequences |
| Q15 | Runtime instance (added after #630) | **Add a Node-scoped Runtime instance.** It owns install, version, environment, secrets, auth, catalog, and processes. Agents reference an instance; Runtime is the kind. Supersedes the "Runtime is a value" part of Q10. | §1 |
| Q16 | ACP version (added) | **ACP v2 is the protocol baseline.** Recorded, with its Turn mapping and the decision to support no ACP v1, in [ADR 0019](0019-acp-v2-protocol-baseline.md) (#633). | §4 |

## Fitness check

`make docs-check` validates this record and the index. The delivering issues add
fitness tests that enforce the decision:

- no Gnostic-owned Turn update kind beyond the envelope's terminal states;
- no Timeline field on the Agent model, and no Gnostic-owned type, wire
  operation, or manifest key named Ascendant;
- no stored singular operator on the Timeline;
- no tool or conversation operation defined on Axoloty outside the Turn
  envelope and the gateway's remote calls.

## Reconsideration triggers

- ACP standardizes discovery, or its HTTP or WebSocket transport completes and
  an agent fleet uses it.
- ACP standardizes a durable client turn identifier that can replace
  `clientTurnID`.
- A real use case needs concurrent Sessions on one Timeline.
- The Agent and Runtime terms confuse users in practice (Q1).
- A Runtime instance's mutable state makes span capture insufficient for
  reproducing a Run (Q15).

## Links

- [#626 — this decision](https://github.com/phynics/Gnostic/issues/626)
- [Epic #602 — ACP-first host](https://github.com/phynics/Gnostic/issues/602)
- [ADR 0001 — Axoloty-native multi-backend host](0001-axoloty-native-multi-backend-host.md)
- [ADR 0003 — Pre-1.0 manifest and protocol reset](0003-pre-1-0-manifest-and-protocol-reset.md)
- [ADR 0017 — ACP-first host and the Gnostic harness agent](0017-acp-first-host-and-harness-agent.md)
- [ACP session setup](https://agentclientprotocol.com/protocol/session-setup)
- [Epic #140](https://github.com/phynics/Gnostic/issues/140)
- [RESET-001 #145](https://github.com/phynics/Gnostic/issues/145)
