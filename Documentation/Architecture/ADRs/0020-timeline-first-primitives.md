# ADR 0020 — Timeline-first primitives: no Agent, a Session record, Projects, and Runtime kinds

## Status

**Proposed** (2026-10-15). The owner set the direction in a design review the
same day. The decisions below record that direction. The questions in
[Open questions](#open-questions) are not yet decided. Owning issue:
[GNO-ACPF-018 #635](https://github.com/phynics/Gnostic/issues/635), under
[Epic #602](https://github.com/phynics/Gnostic/issues/602). Checked by the
[Epic #140](https://github.com/phynics/Gnostic/issues/140) and
[RESET-001 #145](https://github.com/phynics/Gnostic/issues/145) documentation
gates.

It is a direction decision. It changes no code, wire contract, or manifest
shape by itself. Delivery is tracked by the #602 children named in each
section.

This record supersedes:

- [ADR 0018](0018-gnostic-primitives-after-the-acp-pivot.md) §1 and §2 (the
  Agent and its definition), §6 (Workspace delivery as roots or tools), and §7
  (capabilities);
- [ADR 0017](0017-acp-first-host-and-harness-agent.md) §6 (one Gnostic harness
  agent that hosts every inner module), and §5 where it places outer modules
  inside the host.

It amends:

- ADR 0018 §3: a span records a Session record, not an Agent (§4 below);
- ADR 0018 §4: the Turn envelope addresses a Timeline, not an Agent (§3 below);
- ADR 0018 §5: Axoloty advertises Nodes, Runtime instances, Timelines, and
  Workspaces, not Agents;
- ADR 0018 Q14: the Timeline record is the Timeline's content (§2 below,
  question O2);
- [ADR 0019](0019-acp-v2-protocol-baseline.md) §6: no Workspace is delivered as
  a root under the first placement strategy (§6 below).

ADR 0019's protocol decisions are unchanged.

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
  and every object carries `_meta`. Messages, tool calls, and compactions are
  keyed (`messageId`, `toolCallId`, `compactionId`), so chunks fold into
  entities.
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
- **A closed session can be resumed.** v2 `session/close` frees "the resources
  associated with that active session". Removing a persisted session is a
  separate, optional `session/delete`.
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

- **Lossless.** Every update object is stored with its `_meta`. A kind, content
  block, or tool-call content that Gnostic does not recognize (`other`, an
  unstable kind, or a future kind) is stored as received, in order. Nothing is
  dropped or rejected.
- **Folded entities.** Chunks and upserts that share an ID (`messageId`,
  `toolCallId`, `compactionId`, plan entries) are folded into one entity:
  user message, agent message, thought, tool call, plan, compaction, terminal
  output, notice. The Timeline keeps each entity's final ACP object and its
  position. Unkeyed updates are kept as single entries.
- **Session state is not Timeline content.** `state_update`, `usage_update`,
  `available_commands_update`, `config_option_update`, and
  `session_info_update` describe the live session. They are recorded on the
  Turn envelope (terminal outcome, usage) or on the Session record (§4), not as
  Timeline entries.
- **Subagents.** A `subagent_update` creates or updates a child Timeline
  (ADR 0017 §4). Its `session_message` entries belong to the child.
- The Timeline record (#605) is this content. The Turn event log stays
  digest-only (ADR 0014). Whether the record is always on, or opt-in as in
  ADR 0018 Q14, is question O2.

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
- the exact `cwd`, the `additionalDirectories`, and the MCP server
  declarations that the session was set up with, so that a resume can send
  them again;
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
- **Idle.** Gnostic may close an idle session (`session/close`) to free
  resources. The record becomes `resumable`.
- **Failure.** If `session/resume` fails, the record becomes `lost`. Gnostic
  opens a new session and seeds it from the whole Timeline. It never guesses
  whether the old session survived (ADR 0019 §2).
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

- **Scratch Project.** The `cwd` is a Gnostic-owned directory for the Timeline
  on the Runtime's Node, under the state home, at a stable path so that resume
  can send the same `cwd` (O4).
- **Workspaces through the gateway.** Every attached Workspace reaches the
  Runtime as tools of the Gnostic gateway, an MCP server that the Runtime's
  Node passes in `mcpServers` (ADR 0017 §3). Every call crosses Gnostic's
  effective-status and permission checks. Remote Workspaces are reached over
  Axoloty behind the gateway. The gateway's MCP transport is question O3.
- **No roots.** No Workspace is delivered as a root under this strategy.
  ADR 0018's opt-in root delivery (Q12) is kept for a later strategy.

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

A Runtime is one of two kinds. Both implement one Gnostic Runtime contract with
the ACP v2 session lifecycle: new, resume, close, prompt, cancel, and the update
stream.

- **ACP Runtime.** An external harness spoken to over ACP v2 (ADR 0019).
- **Native Runtime.** A Runtime built in this repository that runs inside the
  Node, without ACP framing. It emits ACP v2 update objects, so its Timelines
  look like any other. It is siloed: its own targets, reached only through the
  Runtime contract, and it never reaches into Gnostic's internals.

Experiments map onto these kinds:

- **Inner experiments are Native Runtimes.** Atlas, the semantic context
  compiler, Ouroboros, Akasha, Letta, and the PositronicKit-based harness each
  become a Native Runtime (#609, #616–#619, #611). This replaces ADR 0017 §6's
  single harness agent. The PositronicKit firewall is unchanged: only Native
  Runtime targets may import PositronicKit, and `GnosticCore`,
  `GnosticProtocol`, and `GnosticClient` stay free of it.
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
markers. Capabilities return only when a concrete need appears.

- The ACP adapter still reads the Runtime's `initialize` result where the
  protocol requires it, for example before sending `additionalDirectories` or
  choosing an MCP transport. That is protocol handling, never a Gnostic
  primitive or an advertised value.
- A Node advertises what it hosts (Runtime instances, Timelines, Workspaces) and
  its `protocolMajor`. That is discovery data, not a capability check.
- ADR 0018 Q6's per-Node payload threshold is an advertisement field.

### 9. Axoloty direction

Axoloty stays the discovery and routing fabric (ADR 0018 §5). A move of
Axoloty onto Zenoh is expected. It needs its own record: it changes the MQTT
assumptions of the transport and of the container's deterministic Mosquitto
test service.

## Open questions

| # | Question | Recommendation |
| --- | --- | --- |
| O1 | Where do session configuration and permission policy live without an Agent? | Defaults on the Runtime instance; session configuration options may be overridden when a Timeline is created and are stored on the Session record. Permission policy stays per Runtime instance. |
| O2 | Is Timeline content always stored? | Yes, on a Node with a state home, since handoff needs it. A Node without one keeps it in memory. The Turn event log stays digest-only. |
| O3 | Which MCP transport does the gateway use? | stdio first: a `gnostic` bridge process that the Runtime starts, connected to its Node over a local socket, since stdio is the transport Runtimes support most. HTTP when the Runtime advertises it. MCP-over-ACP once that draft stabilizes. |
| O4 | How long does a scratch Project live? | As long as its Timeline, at a stable per-Timeline path, because resume requires the same `cwd`. |
| O5 | Can a Native Runtime receive a whole Timeline? | Yes, later. The first Native Runtime contract matches ACP's lifecycle; a whole-Timeline handoff is added when the first Native Runtime needs it. |
| O6 | Does the scratch strategy expose the Runtime Node's filesystem? | Yes: a harness's own file and shell tools are not confined by `cwd`. Isolation is a Runtime instance concern (#631). Record it in the compatibility declaration. |
| O7 | What does `gnostic acp` list for editors? | Runtime instances and their Timelines, in place of profiles. |
| O8 | How is an experiment Timeline marked? | A label map on the Timeline, with a reserved `experiment` key. |

## Invariant

- Gnostic identity is Node, Runtime instance, Timeline, Workspace, Project, and
  Turn. A Runtime's session is never Gnostic identity.
- A Timeline stores every ACP v2 update it receives, including kinds Gnostic
  does not recognize, without loss.
- A Session record is resumed only with the `cwd` it was created with.
- Under the scratch strategy, every Workspace call crosses the gateway's
  effective-status and permission checks.
- Only Native Runtime targets may import PositronicKit.
- No Gnostic-owned capability set exists.

## Rejected alternatives

- **Keep the Agent (ADR 0018 §1).** It duplicates the harness's own identity and
  instructions, and most Runtimes cannot receive Gnostic instructions.
- **Store the ACP session ID on the Timeline.** One field holds only the current
  Runtime. Returning to an earlier Runtime instance needs one record per pair.
- **Store the ACP session ID on the span.** A span is attribution for a stretch
  of history; one session can serve several spans.
- **Store only Gnostic-known update kinds.** Handoff and inspection would lose
  whatever Gnostic has not modelled yet.
- **Store the raw update stream only.** Every reader would refold chunks, and
  seeding needs entities.
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

- #629 drops the Agent rename: the envelope addresses Timelines and the
  `protocolMajor` change removes Ascendant addressing;
- #605 stores the Timeline content of §2 and the Session records of §4;
- #606 delivers the gateway and the scratch placement of §6;
- #607 is replaced by the Runtime instance defaults of O1;
- #609, #611, and #612 are revised for Native Runtimes and consumer-side outer
  experiments (§7);
- #613 implements delta and full seeding (§3, §4);
- #631 hosts Runtime instances per Node (§5).

## Consequences

- **No Agent rename.** Gnostic-owned code, wire operations, the manifest, and
  the CLI drop "Ascendant" without a successor. Clients address Timelines and
  choose Runtime instances.
- **The Timeline record becomes central.** It is the content a handoff needs,
  and its size grows with every Turn.
- **Sessions are cheap to free.** Closing an idle session frees the Runtime's
  resources and keeps it resumable.
- **The first placement keeps Gnostic in every Workspace call,** and leaves the
  Runtime's native file tools working only in the scratch directory, where
  there is nothing of the user's.
- **In-process Runtimes return as Native Runtimes.** #611 retires the
  in-process backend contract, not in-process execution.
- **Outer modules as host hooks** (ADR 0017 §5, #612) give way to consumers.

## Fitness check

`make docs-check` validates this record and the index. The delivering issues
add fitness tests that enforce it:

- no Gnostic-owned type, wire operation, or manifest key named Agent or
  Ascendant that denotes a Gnostic identity;
- a Timeline store round-trips an unknown update kind byte-for-byte in its
  JSON value;
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
