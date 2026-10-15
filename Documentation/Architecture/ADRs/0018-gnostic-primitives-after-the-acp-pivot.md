# ADR 0018 — Gnostic primitives after the ACP pivot: Agent, Runtime, spans, and ACP-native Turns

## Status

**Proposed** (2026-10-15). Owning issue:
[GNO-ACPF-014 #626](https://github.com/phynics/Gnostic/issues/626), under
[Epic #602](https://github.com/phynics/Gnostic/issues/602). Builds on
[ADR 0017](0017-acp-first-host-and-harness-agent.md). Checked by the
[Epic #140](https://github.com/phynics/Gnostic/issues/140) and
[RESET-001 #145](https://github.com/phynics/Gnostic/issues/145) documentation
gates.

This record proposes how Gnostic's primitives change now that every Ascendant
Backend is an ACP agent. Its main proposal is that one Gnostic-owned primitive,
the **Agent**, replaces the Ascendant, and that the ACP program an Agent runs
on becomes a value, its **Runtime**. It changes no code, glossary entry, wire contract, or
manifest shape while it is Proposed. The owner decides the
[open questions](#open-questions) first. On acceptance:

- `CONTEXT.md` is revised as described in [Glossary changes on acceptance](#glossary-changes-on-acceptance);
- the records it amends receive status notes. On acceptance, it amends:
  - [ADR 0001](0001-axoloty-native-multi-backend-host.md): "Axoloty-native"
    narrows to discovery and routing (§5);
  - [ADR 0011](0011-external-acp-backends.md): the Ascendant Backend becomes
    the Runtime (§1);
  - [ADR 0017](0017-acp-first-host-and-harness-agent.md) in several places:
    - §2: the Timeline record stores ACP payloads as received, not normalized
      updates (§4);
    - §3 and its Workspace invariant: root delivery is an owner-decided
      exception (§6, Q12);
    - §4: a child Timeline records its operating Agent;
    - §5 and §6: the Agent definition and the Regime merge (§1);
- each affected child issue of #602 takes the decision into its scope.

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
  `additionalDirectories` (Completed), which an agent's own file and shell
  tools use directly. Serving a local directory as gateway tools duplicates the
  agent's native tools and is worse at the same job.

## Decision (proposed)

### 1. One configured primitive, the Agent, with a Runtime as its value

Two concepts remain after the pivot, but only one needs identity.

- **Agent (Gnostic-owned primitive).** A named, advertised, addressable
  configuration. It holds:
  - its **Runtime**;
  - instructions;
  - session configuration (model, mode, and inner-module settings);
  - permission policy;
  - outer modules;
  - default Workspace attachments.

  Clients discover it on the network and address Turns to it, and Regimes are
  compared across it. Its UUID is Gnostic identity. The Agent definition **is**
  its Regime, so there is one configuration object, not two. Changing the
  Runtime makes a different Regime, and therefore a different Agent.
- **Runtime (value, not identity).** The ACP program an Agent runs on: Claude
  Agent, Codex, opencode, or the Gnostic harness agent. It is identified by its
  launch specification or an ACP registry identifier. Gnostic records the name
  and version the program reports. One Runtime can back many Agents (a reviewer
  and a researcher on Claude Agent). A cross-Runtime comparison (#614) compares
  two Agents whose definitions differ only in their Runtime. The Run record
  names both Agents and the one field that differs.
- **Session (external state).** One ACP session of a Runtime. It serves one or
  more spans of one Timeline (section 3); a `resumed` or `loaded` span reuses an
  earlier Session. It is backend-private state, as in ADR 0011.
  Gnostic records it but never treats it as identity.

An Agent has **no memory and no Timelines of its own**:

- the private Timeline and the per-Agent default Timeline are retired;
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
- its Runtime and Session (a new Session, or a reused one);
- the first and last Turn;
- how it began: `new`, `resumed`, `loaded`, `seeded` (with its strategy and
  what was lost), or `forked`.

A Timeline has at most one open span at a time.

- The Timeline's **current operator** is the Agent of its open span. It
  replaces the stored `operatingAscendantID`.
- A Turn addressed to a Timeline runs in its open span. Opening a span for a
  different Agent is how a Timeline switches agents; Q3 decides how a client
  asks for that.
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
- **Gnostic interprets only what it needs:**
  - the terminal outcome;
  - tool-call identifiers, for permission correlation;
  - usage numbers, for metering;
  - assistant message chunks, only to build the assistant-text snapshot that the
    Turn event log's compaction keeps (ADR 0014).

  It passes the rest through. Update kinds it does not know are forwarded and
  recorded unchanged, never rejected. This is the forward-compatibility rule.
- **Permission is a request and reply, not an update.** ACP's
  `session/request_permission` expects an answer. The envelope carries it as a
  correlated permission request to the Turn's client, holding the ACP tool call
  and options, and a correlated reply.
  - This reuses the existing permission correlation (ADR 0011 mediation;
    `AscendantPermissionCoordinator`).
  - A timeout, a lost connection, or a Node failure answers the Runtime with a
    cancelled outcome. Gnostic records it as `unavailable`, not as a denial.
  - Replaying a Turn returns the recorded decision and never prompts again.
- **Replay identity.** The `clientTurnID` conflict check hashes the canonical
  form of the prompt payload: JSON Canonicalization Scheme (RFC 8785) over the
  content blocks, plus the ACP version tag. Retries that differ only in key
  order therefore still match.
- **Size.** Until Q6 is decided, a Turn whose payload exceeds the Axoloty event
  budget or the journal bound is rejected with an explicit failure code, as
  oversize prompts already are. It is never truncated or dropped.
- **Payload-free diagnostics stay payload-free.** Diagnostics, metering, and the
  console read only envelope fields and usage numbers. They never read tool-call
  titles, `rawInput`, paths, or any content block.
- **For text-only consumers,** `GnosticClient` offers a projection helper (for
  example, assistant text only). The projection is a client convenience, not
  the wire format.
- **This changes the wire contract.** It needs a new `protocolMajor` (ADR 0003)
  and lands inside the 0.5.0 line, before the stable surface is declared
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

**Root delivery bypasses Gnostic mediation, so it is opt-in (pending Q12).**
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
on resume or load. When the Runtime supports neither resume nor load, changing
roots opens a new seeded span.

Q9 decides what `cwd` is when no root Workspace is attached.

### 7. Capabilities come from the Runtime

An Agent's advertised capabilities are derived from:

- the Runtime's ACP `initialize` result: load and resume, prompt content types,
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
  and recorded per span (Q12).
- Diagnostics and metering never read Turn payload content.

## Rejected alternatives

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

None in this record. On acceptance:

- the Turn envelope change raises `protocolMajor`, delivered by a new child of
  #602;
- the manifest renames Ascendants to Agents, and loses `defaultTimelineID` and
  `operatingAscendantID` in favour of spans (#607 and #613);
- the frontend (`gnostic acp`) and the ACP backend pass payloads through. Both
  can share one ACP model (#572).

No new package dependency.

## Consequences

If accepted:

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

## Glossary changes on acceptance

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

## Open questions

The owner decides these before acceptance. A recommendation follows each
question.

- **Q1 — One primitive, and its name.** Retire "Ascendant" and use **Agent**
  (with **Runtime** for the ACP program), as proposed in sections 1 and 2? The
  alternatives are keeping "Ascendant" with the profile meaning, or "Profile".
  *Recommendation:* Agent and Runtime, renamed together with the `protocolMajor`
  change.
- **Q2 — Default Timeline.** Should an Agent still name a default Timeline,
  as a convenience for "send a Turn without picking a Timeline"?
  *Recommendation:* no. The frontend or client creates a Timeline on first use.
- **Q3 — Switching agents.** Can a Turn addressed to a Timeline name a different
  Agent and implicitly open a new seeded span? Or must switching be an
  explicit Timeline operation? *Recommendation:* an explicit operation, so a
  lossy seeding step never happens by accident.
- **Q4 — Concurrent spans.** Confirm at most one open span per Timeline, with
  parallel work as child Timelines. *Recommendation:* confirm.
- **Q5 — ACP versions.** When ACP v2 ships, do payloads carry a per-Turn ACP
  version, with Gnostic converting at the edges when peers differ? Or does
  Gnostic raise `protocolMajor` again? *Recommendation:* tag the ACP version in
  the envelope, and convert only at the edge that needs it.
- **Q6 — Payload size.** ACP content blocks (images, embedded resources) can
  exceed the bounded Axoloty event budget. Chunk them, send them as resource
  links to a Gnostic-served blob, or cap them? *Recommendation:* resource links
  above a size threshold, with the threshold advertised as a Node capability.
- **Q7 — Axoloty scope.** Confirm Axoloty stays the cross-Node fabric for
  0.5.0, and that ACP over HTTP is only a reconsideration trigger.
  *Recommendation:* confirm.
- **Q8 — Remote roots.** Should a remote filesystem Workspace ever become a root
  (by mount or sync), or always be tools-only? *Recommendation:* tools-only.
  Mounting is an operator concern outside Gnostic.
- **Q9 — `cwd` with no root.** When no root Workspace is attached, is `cwd` a
  Gnostic-owned scratch directory per Timeline under the state home, or is a
  root Workspace required to start a session? *Recommendation:* a per-Timeline
  scratch directory, reported as such in the record.
- **Q10 — Runtime identity.** Identify Runtimes by ACP registry ID when one exists,
  falling back to a launch-spec fingerprint? *Recommendation:* yes. The fingerprint covers the command, arguments, and the names of the environment variables, never their values or any secret.
- **Q11 — Delivery order.** Land the envelope change (section 4) before or after
  the Timeline record (#605)? *Recommendation:* the envelope first, so the record
  stores ACP payloads from day one.

- **Q12 — Root delivery and mediation.** Allow root delivery at all, given that
  the Runtime's native tools then reach the directory without Gnostic's
  effective-status and permission checks (§6)? *Recommendation:* yes, opt-in per
  attachment, with the limits in §6. A local repository served only as gateway
  tools is a much worse coding experience than the Runtime's own tools.
- **Q13 — Replay hash basis.** Confirm RFC 8785 canonical JSON of the prompt
  content blocks plus the ACP version tag as the `clientTurnID` conflict basis
  (§4). *Recommendation:* confirm.
- **Q14 — Content at rest.** Confirm the split: the Turn event log stays
  digest-only (ADR 0014), and only the opt-in Timeline record stores ACP payload
  content. *Recommendation:* confirm.

Q1, Q4, and Q7 are recommendations that the body already assumes. Answering
"no" to any of them reopens the matching section (§1–2, §3, §5).

## Fitness check

While Proposed, `make docs-check` validates this record and the index. On
acceptance, the delivering issues add fitness tests that enforce the decision:

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

## Links

- [#626 — this decision](https://github.com/phynics/Gnostic/issues/626)
- [Epic #602 — ACP-first host](https://github.com/phynics/Gnostic/issues/602)
- [ADR 0001 — Axoloty-native multi-backend host](0001-axoloty-native-multi-backend-host.md)
- [ADR 0003 — Pre-1.0 manifest and protocol reset](0003-pre-1-0-manifest-and-protocol-reset.md)
- [ADR 0017 — ACP-first host and the Gnostic harness agent](0017-acp-first-host-and-harness-agent.md)
- [ACP session setup](https://agentclientprotocol.com/protocol/session-setup)
- [Epic #140](https://github.com/phynics/Gnostic/issues/140)
- [RESET-001 #145](https://github.com/phynics/Gnostic/issues/145)
