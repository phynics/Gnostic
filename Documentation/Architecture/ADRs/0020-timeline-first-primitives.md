# ADR 0020 — Timeline-first primitives: no Agent, a Session record, Projects, and Runtime kinds

## Status

**Accepted** (2026-10-15). The owner set the direction in a design review the
same day, decided O9 (Native Runtimes are special Nodes), and accepted the
recommended answer to O1–O8. See [Owner decisions](#owner-decisions). Owning issue:
[GNO-ACPF-018 #635](https://github.com/phynics/Gnostic/issues/635), under
[Epic #602](https://github.com/phynics/Gnostic/issues/602). Checked by the
[Epic #140](https://github.com/phynics/Gnostic/issues/140) and
[RESET-001 #145](https://github.com/phynics/Gnostic/issues/145) documentation
gates.

It is a direction decision. It changes no code, wire contract, or manifest
shape by itself. Delivery is tracked by the #602 children named in each
section.

This record supersedes:

- in [ADR 0018](0018-gnostic-primitives-after-the-acp-pivot.md):
  - the Agent bullets of §1, and the paragraph that an Agent holds no memory.
    The Runtime kind, the Runtime instance (Q15), and the Session definitions in
    §1 stay;
  - §2, except its code-naming rule: types for the ACP protocol role keep the
    ACP SDK's names or an `ACP` prefix;
  - §7 (capabilities);
  - Q1 and Q2;
- in [ADR 0017](0017-acp-first-host-and-harness-agent.md):
  - §5 (the Ascendant definition), replaced by Runtime instance defaults (O1);
  - §6 (one Gnostic harness agent that hosts every inner module, and outer
    modules as host hooks).

It amends:

- ADR 0018 §3, Q3, and the current operator: a span records a Session record,
  and the current operator is the Runtime instance of the open span's Session
  record (§4 below). Switching a Timeline's Runtime instance is the explicit
  operation Q3 required for switching Agents;
- ADR 0018 §4: the Turn envelope addresses a Timeline, not an Agent (§3 below);
- ADR 0018 §5: Axoloty advertises Nodes, Runtime instances, Timelines, and
  Workspaces, not Agents;
- ADR 0018 §6 and Q12: root delivery stays the opt-in exception it defines, but
  the first placement strategy (§6 below) delivers no roots;
- ADR 0018 Q14 and the Timeline record: §2 below (O2);
- ADR 0018's invariants and fitness check: read "Agent" as "Runtime instance"
  where they concern the operator, and drop the Agent-model rules;
- ADR 0017 §4: a child Timeline records its Session record, not an operating
  Ascendant. Delegation (#608) runs a Turn on another Runtime instance;
- [ADR 0019](0019-acp-v2-protocol-baseline.md) §7 and T2: where they say "the
  Agent switches", read "the Timeline switches Runtime instance".

ADR 0019's protocol decisions, including the MCP transport order of its §6,
are unchanged.

## Context

ADR 0018 kept one configured primitive, the Agent, between a client and a
Runtime. The owner's review found that several of its assumptions do not hold.

- **A harness already carries its own identity.** Each harness has its own
  system prompt, tools, and configuration. A Gnostic-level Agent with its own
  instructions duplicates the harness's. ACP has only an unstable,
  optional `systemPrompt` on `session/new` (the client-system-prompt RFD), so
  most Runtimes cannot receive Gnostic instructions at all.
- **The Timeline is what Gnostic must own.** The owner's goal is to store a
  Timeline as a list of Turns and hand it to a different Runtime. That needs
  the Timeline to keep everything a Runtime sends, not a Gnostic subset.
- **ACP v2 defines a closed set of update kinds, each extensible.** The v2
  schema (`agentclientprotocol/agent-client-protocol` 39ae6a2) has 20 stable
  `SessionUpdate` kinds, four unstable ones (`plan_removed`, `subagent_update`,
  `session_message`, `session_message_chunk`), six content block kinds, and
  four tool-call content kinds. Each set has an `other` member for extensions,
  and every object carries `_meta`. Messages, tool calls, compactions,
  terminals, and plans are keyed (`messageId`, `toolCallId`, `compactionId`,
  `terminalId`, `planId`), so chunks can be folded into entities.
- **ACP cannot import history.** `session/new` accepts `cwd`,
  `additionalDirectories`, `mcpServers`, and (unstable) `systemPrompt`.
  `session/resume` and `session/fork` work only on the Runtime's own sessions.
  Handing a Timeline to another ACP Runtime is therefore always a seeding
  step through the prompt.
- **Every ACP session has a working directory.** `cwd` is required on
  `session/new`, `session/resume`, and `session/fork`. It "MUST be used for the
  session regardless of where the Agent subprocess was spawned", so it is a path
  on the Runtime's machine. A resume may change `additionalDirectories` only "as
  long as the request `cwd` matches the session's `cwd`". `mcpServers` is
  required again on every resume.
- **A closed session is probably resumable.** v2 `session/close` frees "the
  resources associated with that active session", and removing a persisted
  session is a separate, optional `session/delete`. The spec does not say
  outright that a closed session can be resumed; this record infers it and
  falls back to seeding when it cannot (§4).
- **ACP v2 has no client filesystem.** v2 removes `fs/*` and `terminal/*` (the
  client-filesystem-terminal RFD) and points clients to MCP servers instead.
  A Runtime's file and shell tools act on its own machine.
- **The capability set has lost its purpose.** `AscendantInteroperabilityCapability`
  (nine IDs) lets clients pick an Ascendant by behavior. ADR 0019 §7 requires
  every v2 Runtime that advertises sessions to support the lifecycle those IDs
  described.
- **Experiments do not all fit one harness.** ADR 0017 §6 put every inner
  experiment inside one ACP harness agent, and outer modules inside the host.
  The owner wants each inner experiment to be its own Runtime, and outer
  experiments to use Gnostic from outside.

## Decision

### 1. The Timeline is the primary primitive; there is no Agent

Gnostic has no Agent primitive and no Agent definition. The Ascendant is
retired without a successor identity.

- Gnostic identity is **Node, Runtime instance, Timeline, Workspace, Project,
  and Turn**.
- A harness's instructions, tools, and defaults stay the harness's. Gnostic does
  not hold instructions for a Runtime. Where a use case needs them, the
  unstable ACP `systemPrompt` is a per-Session option (O1), not a primitive.
- A client starts work by creating a Timeline on a Runtime instance. It
  addresses Turns to the Timeline.
- **Regime** stays as an experiment term and a Run record field. A Regime is
  the Runtime instance, its session configuration options, the placement
  strategy, and the Workspaces a Run uses. It is not a stored primitive.

### 2. The Timeline stores everything ACP sends

A Timeline is an ordered list of Turns, organized in spans (ADR 0018 §3,
amended by §4 below). Its content is complete for ACP v2.

- **The ordered update log is the record.** Every `session/update` the
  Runtime sends is stored as received, in arrival order, with its `_meta`. That
  includes every chunk, every intermediate `tool_call_update`, and the session
  state kinds (`state_update`, `usage_update`, `available_commands_update`,
  `config_option_update`, `session_info_update`). A kind, content block, or
  tool-call content that Gnostic does not recognize (`other`, an unstable kind,
  or a future kind) is stored the same way. Nothing is dropped or rejected.
- **Folded entities are a derived index.** Updates that share an ID
  (`messageId`, `toolCallId`, `compactionId`, `terminalId`, `planId`) are folded
  into entities: user message, agent message, thought, tool call, plan,
  compaction, terminal output. Seeding, inspection, and the console read the
  index. It can always be rebuilt from the log.
- **Session state is a derived view.** The latest session state is read from
  the log onto the Session record (§4) and the Turn envelope (terminal outcome,
  usage). It is never the only copy.
- **Subagents.** A `subagent_update` creates or updates a child Timeline
  (ADR 0017 §4). Its `session_message` entries belong to the child. The child's
  session is created by the Runtime, so its Session record takes the `cwd` the
  Runtime reports, or none, and it is resumed only through its parent.
- The Timeline record (#605) is this content. It is always stored on a Node
  with a state home, since handoff needs it; a Node without one keeps it in
  memory (O2). This replaces ADR 0018 Q14's opt-in. The Turn event log stays
  digest-only (ADR 0014).

### 3. A Turn is one prompt lifecycle, and the unit of handoff

ADR 0019 §2 already defines the Turn boundaries. A Turn is the user message
inserted by `session/prompt` (its `messageId`) and every Timeline entry until
the next `idle` `state_update`. Updates outside a Turn belong to the open span
(ADR 0019 §3).

- The Turn envelope (ADR 0018 §4) addresses a **Timeline**. It drops the
  addressed Agent and records the Session record that served the Turn.
- **Handoff.** A Timeline moves to another Runtime instance by an explicit
  Timeline operation (ADR 0018 Q3) that opens a new span.
  - To an **ACP Runtime**, the Turns are seeded through the first prompt of a
    new session, using a declared seeding strategy (#613). The record states
    what was lost: other harnesses' thoughts and tool calls cannot be replayed
    natively.
  - To a **Native Runtime** (§7), the Timeline may be handed over whole (O5).

### 4. The Session record makes a Timeline stick to a Runtime

Gnostic persists one **Session record** for each pair of Timeline and Runtime
instance that has served it. It holds:

- the Timeline, the Node, and the Runtime instance;
- the ACP `sessionId`;
- the exact `cwd` and `additionalDirectories` the session was set up with;
- the MCP servers it was given, **by reference** (the gateway and which
  Workspaces it served), never their environment, headers, or tokens. Resume
  regenerates the declarations with fresh credentials;
- `syncedThrough`: the last Turn this Runtime session has seen;
- the session configuration options in effect;
- its state: `live`, `resumable`, or `lost`.

Rules:

- A span records its Session record. One Session record can serve several spans,
  for example when a Timeline returns to a Runtime instance it used before.
- **Stickiness.** A Timeline's open span names a Session record, and therefore a
  Node and a Runtime instance. Turns route there over Axoloty.
- **Returning.** When a Timeline returns to a Runtime instance whose session is
  `resumable`, Gnostic resumes that session with the stored `cwd` and sends only
  the Turns after `syncedThrough` (a delta seed).
- **Seed prompts are not Turns.** A seed (full or delta) is recorded on the
  span and on the next Turn's envelope as seeding metadata. It never appears in
  the Timeline as a user Turn.
- **Idle.** Gnostic may close an idle session (`session/close`) to free
  resources. The record becomes `resumable`.
- **Failure.** The record becomes `lost` only on a definitive answer: the
  Runtime rejects `session/resume` for that session (for example with
  `-32602`), or the Runtime instance is removed. A transport failure or a
  crashed process is retried and leaves the record `resumable`. After `lost`,
  Gnostic opens a new session and seeds it from the whole Timeline. It never
  guesses whether the old session survived (ADR 0019 §2).
- A Session record is never Gnostic identity. Losing the Runtime's session loses
  no Timeline content.

### 5. Runtime instances are hosted by Nodes

Each Node hosts its own Runtime instances (ADR 0018 Q15) and advertises them
on Axoloty. Requests for a Runtime instance route to its Node. Runtime
configuration is not distributed: it lives on the hosting Node. Distributed
configuration is deferred and is a reconsideration trigger.

### 6. Projects and placement: the first strategy is a scratch directory with gateway Workspaces

A **Project** names where a session starts: the `cwd`. Every Session has one.
A **Workspace** stays a capability resource that is added to a Timeline.

**Placement** decides how a Session's Project and Workspaces reach the Runtime.
Gnostic has one placement strategy now:

- **Scratch Project.** The `cwd` is a Gnostic-owned directory on the Runtime's
  Node, one per Session record, at a stable path so that resume can send the
  same `cwd`. It lives outside the tree that holds Timeline records and Runtime
  instance secrets and auth, under a random (UUID) name, with owner-only
  permissions (mode `0700`). A new Session record never inherits another
  Runtime's scratch files, so instructions or configuration one harness wrote
  there do not leak into the next. It lives as long as its Session record is
  `live` or `resumable`, and is removed when the record is `lost` or its
  Timeline is deleted (O4).
- **Workspaces through the gateway.** Every attached Workspace reaches the
  Runtime as tools of the Gnostic gateway, an MCP server that the Runtime's
  Node passes in `mcpServers` (ADR 0017 §3). Every gateway call crosses
  Gnostic's effective-status and permission checks. Remote Workspaces are
  reached over Axoloty behind the gateway. The gateway picks its transport as
  ADR 0019 §6 decides (MCP-over-ACP, then HTTP, then stdio, each only when the
  Runtime advertises it). When the Runtime advertises none, every Workspace is
  `unsupported` for that Session, and the Session still runs.
- **No roots.** No Workspace is delivered as a root under this strategy.
  ADR 0018's opt-in root delivery (Q12) is kept for a later strategy.
- **The scratch directory is not a sandbox.** A harness's own file and shell
  tools are not confined by `cwd`. They can reach anything the Runtime
  instance's OS user can, including a local Workspace's directory on the same
  Node, bypassing the gateway, `unavailable`, and read-only. Until Runtime
  instance isolation (#631) confines a Runtime instance, a Workspace attached
  `unavailable` or read-only must not live on a Node where an unisolated
  Runtime instance runs as a user that can write it. The 0.5.0 compatibility
  declaration states this.

Later strategies are recorded as direction, not decided:

- **Local Project:** a directory on the Runtime's Node, which can be delivered
  as `cwd` and roots;
- **Git Project:** a repository URL and ref that the Node clones or fetches,
  possibly one worktree per Timeline;
- **Remote launch:** the Runtime process runs on the Node that holds the
  directory, and its ACP stream is relayed over Axoloty.

A virtual filesystem or a remote shell for the Runtime is not a placement
strategy. It may be tried as an experiment.

### 7. Runtime kinds: ACP Runtimes and Native Runtimes

A Runtime is one of two kinds. Both implement one Gnostic Runtime contract: the
ACP v2 session surface without its JSON-RPC framing. That is `initialize`,
`session/new`, `session/resume` with `replayFrom`, `session/close`,
`session/fork` where offered, `session/prompt` with insertion and its
`messageId`, both cancellation forms (`$/cancel_request` and `session/cancel`),
the `session/update` stream with its `idle` `state_update`, and
`session/request_permission` with its reply. ADR 0019's invariants hold for
both kinds, including T3.

- **ACP Runtime.** An external harness spoken to over ACP v2 (ADR 0019).
- **Native Runtime.** A Runtime built in this repository. It emits ACP v2 update
  objects, so its Timelines look like any other. It is siloed: its own targets,
  reached only through the Runtime contract.

**A Native Runtime is a special Node (owner decision O9).** It is its own
executable: a Node implementation that joins the Gnostic network and hosts one
Runtime instance, itself. It speaks Gnostic, not ACP:

- it advertises its Runtime instance on Axoloty like any Node (§5), and every
  request reaches it the way a request reaches any Node-hosted Runtime
  instance: routed over Axoloty, as Gnostic operations with the Turn envelope
  and its ACP v2 payloads (ADR 0018 §4, §5);
- a Session record names that Node, so stickiness, resume, and seeding work
  unchanged (§4). Its scratch Project lives on that Node (§6);
- a host Node may launch and supervise it on the same machine, or it may run
  on any other machine of the network. Either way it is reached the same way;
- it builds on the Gnostic node and protocol libraries and its own targets. It
  never links the host's composition targets (`GnosticHost`, `GnosticCLI`, the
  runner).

This keeps ADR 0017 §7 intact without an exception: PositronicKit lives only in
the special Node's own executable and targets, never in a host target's
closure. A Native Runtime whose closure is free of PositronicKit may still run
inside a host Node's process, behind the same Runtime contract.

Experiments map onto these kinds:

- **Inner experiments are Native Runtimes.** Atlas, the semantic context
  compiler, Ouroboros, Akasha, Letta, and the PositronicKit-based harness each
  become a Native Runtime (#609, #616–#619, #611). This replaces ADR 0017 §6's
  single harness agent. The PositronicKit firewall is unchanged: the "harness
  agent targets" of ADR 0017 §7 are now the special-Node Native Runtime
  targets, and its transitional allow-list still only shrinks (#604).
- **Outer experiments are Gnostic consumers.** They use Gnostic's client
  surface to set up their test. They present as special Workspaces (their
  tools) and as Timelines labelled `experiment:` (O8). They are not host hooks.
  RLM (#624, #615) is the first.
- **Compositions.** The hosting Node may compose Runtimes, for example a Native
  Runtime that drives an ACP Runtime as a proxy. ACP's proxy-chains RFD is an
  inspiration, not a dependency.

### 8. No Gnostic capabilities for now

The Gnostic interoperability capability set (`AscendantInteroperabilityCapability`,
`GnosticCapability`) is retired, together with the backend optional-capability
markers. Gnostic defines no capability names of its own until a concrete need
appears. The removal changes the wire contract, so it lands with the
`protocolMajor` change of #629. Until then, `RemoteTurnClient` and
`GnosticWorkspaceClient` keep their checks.

- The ACP adapter reads the Runtime's `initialize` result where the protocol
  requires it, for example before sending `additionalDirectories` or choosing
  an MCP transport.
- A Node advertises what it hosts (Runtime instances, Timelines, Workspaces) and
  its `protocolMajor`. Each advertised Runtime instance carries its Runtime's
  ACP `initialize` capabilities **verbatim**, as discovery data, so a client can
  see, for example, that a Runtime takes no image content before sending one.
  Gnostic adds no names to that data and never re-derives it.
- ADR 0018 Q6's per-Node payload threshold is an advertisement field.

### 9. Axoloty direction

Axoloty stays the discovery and routing fabric (ADR 0018 §5). A move of
Axoloty onto Zenoh is expected. It needs its own record: it changes the MQTT
assumptions of the transport and of the container's deterministic Mosquitto
test service.

## Glossary changes

Applied to `CONTEXT.md` with this record:

- **Deprecate:** Agent, Agent definition (use Runtime instance and its
  defaults); Capability, as a Gnostic-defined name; Gnostic harness agent (use
  Native Runtime).
- **Add:** Project, Placement, Session record, ACP Runtime, Native Runtime,
  Timeline label.
- **Redefine:** Session (the Session record); Span (records a Session record);
  Current operator (the Runtime instance of the open span); Timeline record
  (the ordered update log and its fold index); Regime (a Run's Runtime
  instance, session configuration, placement, and Workspaces); Root (kept for a
  later placement strategy); Outer module and Inner module (outer experiments
  are Gnostic consumers; inner experiments are Native Runtimes).

## Owner decisions

| # | Question | Decision | Where |
| --- | --- | --- | --- |
| O1 | Where do session configuration and permission policy live without an Agent? | **Defaults on the Runtime instance.** Session configuration options may be overridden when a Timeline is created and are stored on the Session record. Permission policy stays per Runtime instance. | §1, §4 |
| O2 | Is Timeline content always stored? | **Yes, on a Node with a state home**, since handoff needs it. A Node without one keeps it in memory. The Turn event log stays digest-only. Replaces ADR 0018 Q14's opt-in. | §2 |
| O3 | How does the gateway serve stdio, the last fallback of ADR 0019 §6? | **A `gnostic` bridge process** that the Runtime starts, connected to its Node over a local socket with a per-Session token that is regenerated on resume. | §6 |
| O4 | How long does a scratch Project live? | **As long as its Session record is `live` or `resumable`**, because resume requires the same `cwd`. Removed when the record is `lost` or its Timeline is deleted. | §6 |
| O5 | Can a Native Runtime receive a whole Timeline? | **Yes, later.** The first Native Runtime contract matches ACP's lifecycle; a whole-Timeline handoff is added when the first Native Runtime needs it. | §3, §7 |
| O6 | Is the scratch strategy acceptable for 0.5.0 without Runtime instance isolation? | **Yes**, with the restriction in §6 and a statement in the compatibility declaration. Isolation is delivered by #631. | §6 |
| O7 | What does `gnostic acp` list for editors? | **Runtime instances and their Timelines**, in place of profiles. | Dependency impact |
| O8 | How is an experiment Timeline marked? | **A label map on the Timeline**, with a reserved `experiment` key. | §7 |
| O9 | What carries the Runtime contract to a Native Runtime that cannot run in a host Node's process? | **Native Runtimes are special Node implementations running over Gnostic.** They join the network as Nodes, each hosting its own Runtime instance, and are reached over Axoloty like any Node-hosted Runtime. Neither ACP on stdio nor a separate local channel. | §7 |

## Invariant

- Gnostic identity is Node, Runtime instance, Timeline, Workspace, Project, and
  Turn. A Runtime's session is never Gnostic identity.
- A Timeline stores every ACP v2 update it receives, including kinds Gnostic
  does not recognize, without loss.
- A Session record is resumed only with the `cwd` it was created with.
- A Session record never stores MCP credentials.
- Every gateway call crosses Gnostic's effective-status and permission checks.
  A harness's own tools are outside that guarantee until #631 isolates the
  Runtime instance.
- No host target has PositronicKit in its dependency closure (ADR 0017 §7).
  Only special-Node Native Runtime targets, and the transitional allow-list,
  may depend on it.
- A Native Runtime that depends on PositronicKit is reached only over the
  Gnostic network, as a Node.
- Both Runtime kinds honour ADR 0019's invariants.
- Gnostic defines no capability names of its own.

## Rejected alternatives

- **Keep the Agent (ADR 0018 §1).** It duplicates the harness's own identity and
  instructions, and most Runtimes cannot receive Gnostic instructions.
- **Store the ACP session ID on the Timeline.** One field holds only the current
  Runtime. Returning to an earlier Runtime instance needs one record per pair.
- **Store the ACP session ID on the span.** A span is attribution for a stretch
  of history; one session can serve several spans.
- **Store only Gnostic-known update kinds.** Handoff and inspection would lose
  whatever Gnostic has not modelled yet.
- **Store folded entities only.** It loses chunk order, intermediate tool-call
  states, and session-state history, which audit and replay need.
- **Store the raw log with no fold index.** Every reader would refold chunks,
  and seeding needs entities.
- **Link PositronicKit Native Runtimes into the Node.** It breaks ADR 0017 §7's
  closure rule for every host target.
- **Reach an out-of-process Native Runtime over ACP v2 on stdio.** It ties the
  Runtime to the machine and process of the Node that launched it, and adds a
  second path next to the Gnostic network that already routes to Node-hosted
  Runtime instances (O9).
- **A Gnostic-owned local channel to a child process.** It invents a third
  protocol for one machine only (O9).
- **Persist MCP declarations exactly.** They can hold secrets and per-launch
  tokens that are stale on resume.
- **Deliver Workspaces as roots first.** It needs the Workspace's directory on
  the Runtime's Node, and it bypasses Gnostic's checks (ADR 0018 Q12). The
  gateway works for local and remote Workspaces alike.
- **A virtual filesystem and remote shell as the default placement.** File access
  over the network is slow, tools launched by the harness would still run on
  its own Node, and how a harness starts its shell is harness-specific. ACP v2
  removed the client filesystem methods that would have supported it.
- **Distribute Runtime configuration now.** No use case needs it yet.
- **Keep one harness agent for all inner experiments (ADR 0017 §6).** It couples
  unrelated experiments in one Runtime and one release.
- **Keep the capability set and narrow it.** Nothing consumes it once every
  Runtime supports the v2 session lifecycle.

## Dependency impact

None in this record. Delivery:

- #629 drops the Agent rename: the envelope addresses Timelines, and the
  `protocolMajor` change removes Ascendant addressing and the capability set;
- #605 stores the Timeline content of §2 and the Session records of §4;
- #606 delivers the gateway and the scratch placement of §6;
- #607 is replaced by the Runtime instance defaults of O1;
- #609, #611, and #612 are revised for Native Runtimes and consumer-side outer
  experiments (§7);
- #613 implements delta and full seeding (§3, §4);
- #631 hosts Runtime instances per Node (§5) and isolates them (§6);
- #604 enforces the firewall for special-Node Native Runtimes (§7);
- #609 builds the first special Node, the PositronicKit-based Native Runtime (§7);
- #608 delegates to Runtime instances instead of Agents;
- #614 compares Regimes that differ in Runtime instance instead of Agent;
- #584 shows spans with their Session records;
- `gnostic acp` lists Runtime instances and Timelines instead of profiles (O7),
  owned by #629.

## Consequences

- **No Agent rename.** Gnostic-owned code, wire operations, the manifest, and
  the CLI drop "Ascendant" without a successor. Clients address Timelines and
  choose Runtime instances.
- **The Timeline record becomes central.** It is the content a handoff needs,
  and its size grows with every Turn.
- **Sessions are cheap to free.** Closing an idle session frees the Runtime's
  resources and keeps it resumable.
- **The first placement keeps Gnostic in every gateway call.** The Runtime's
  native tools start in an empty scratch directory, but they are not confined
  to it (§6).
- **Native Runtimes replace the in-process backends.** #611 retires the
  in-process backend contract. PositronicKit-based Native Runtimes run as
  special Nodes on the Gnostic network.
- **Outer modules as host hooks** (ADR 0017 §5, #612) give way to consumers.

## Fitness check

`make docs-check` checks this record's links and the index. The delivering
issues add fitness tests that enforce it:

- no Gnostic-owned type, wire operation, or manifest key named Agent or
  Ascendant that denotes a Gnostic identity;
- a Timeline store returns an unknown update kind as a JSON value equal to the
  one received, `_meta` included;
- a Session record contains no MCP environment, header, or token value;
- no Native Runtime target depends on a host composition target
  (`GnosticHost`, `GnosticCLI`, the runner);
- no host target has PositronicKit in its closure (#604);
- resuming a Session record with a different `cwd` fails before any ACP call;
- no Gnostic capability set or capability check in `Sources`.

## Reconsideration triggers

- ACP standardizes history import, or a whole-Timeline handoff between Runtimes.
- ACP's `systemPrompt` stabilizes and a use case needs Gnostic-held
  instructions.
- ACP v2 reintroduces a client filesystem, or a sandboxing configuration that
  makes remote directories practical.
- A concrete client needs to choose a Runtime by behavior (capabilities).
- Runtime configuration must move between Nodes.
- Axoloty moves to Zenoh.

## Links

- [#635 — this decision](https://github.com/phynics/Gnostic/issues/635)
- [Epic #602 — ACP-first host](https://github.com/phynics/Gnostic/issues/602)
- [ADR 0017 — ACP-first host and the Gnostic harness agent](0017-acp-first-host-and-harness-agent.md)
- [ADR 0018 — Gnostic primitives after the ACP pivot](0018-gnostic-primitives-after-the-acp-pivot.md)
- [ADR 0019 — ACP v2 as Gnostic's protocol baseline](0019-acp-v2-protocol-baseline.md)
- [ACP session setup](https://agentclientprotocol.com/protocol/session-setup)
- [Epic #140](https://github.com/phynics/Gnostic/issues/140)
- [RESET-001 #145](https://github.com/phynics/Gnostic/issues/145)
