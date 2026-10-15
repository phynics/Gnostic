# Gnostic domain constitution

This document is the canonical vocabulary for Gnostic. The relationships below
are Gnostic-owned unless a definition explicitly assigns ownership to a
backend.

## Node

A Node is one Gnostic host. It publishes one `protocolMajor`, hosts its own
Runtime instances, and advertises them, its Timelines, and its Workspaces on
Axoloty. Requests for a Runtime instance are routed to its Node (ADR 0020).

## Runtime

A Runtime is a kind of harness, for example Claude Agent, Codex, opencode, or a
Native Runtime built in this repository. It is a value, not Gnostic identity.
An ACP Runtime is identified by its ACP registry ID, or as `local-command` with
a launch fingerprint over the command, the arguments, and the environment
variable names, never their values or any secret.

A Runtime owns its identity and instructions (its own system prompt), model and
tool semantics, model context, compaction, caches, and its own lifecycle.
Gnostic connects and orchestrates Runtimes and depends on none of them. Every
Runtime implements one Gnostic Runtime contract: the ACP v2 session surface
without its JSON-RPC framing (ADR 0019, ADR 0020). A Runtime is an ACP Runtime
or a Native Runtime.

## ACP Runtime

An ACP Runtime is an external harness that Gnostic speaks to over ACP v2
(ADR 0019).

## Native Runtime

A Native Runtime is a Runtime built in this repository. It emits ACP v2 update
objects, so its Timelines look like any other, and it is reached only through
the Runtime contract. A Native Runtime that depends on PositronicKit is a
special Node: its own executable that joins the Gnostic network, hosts one
Runtime instance (itself), and is reached over Axoloty like any Node-hosted
Runtime instance. It never links the host's composition targets. A Native
Runtime free of PositronicKit may run inside a host Node's process. Inner
experiments are Native Runtimes (ADR 0020).

Only Native Runtime targets, and until #604 and #611 land the transitional
allow-list of ADR 0017, may depend on PositronicKit. PositronicKit types such
as `AgentInstance` and `Thread` stay private to them.

## Runtime instance

A Runtime instance is one configured install of a Runtime kind on one Node. It
owns:

- its install and pinned version, or an executable override;
- its arguments, environment, and secrets;
- its authentication state;
- its advertised catalog of models and session config options;
- its default session configuration options and its permission policy;
- its processes.

Clients choose a Runtime instance when they create a Timeline, and may override
its session configuration options for that Timeline. Two instances never share
mutable state or credentials. A Runtime instance has a Node-scoped ID. Its Node
advertises it together with its Runtime's ACP `initialize` capabilities,
verbatim, as discovery data. Each span records the instance's ID, version, and
launch fingerprint at its start (ADR 0018, ADR 0020, #631).

Until #611 retires them, the in-process `positronic` and `letta` backend kinds
remain valid.

## Session record

A Session record is Gnostic's record of one Runtime session serving a Timeline,
one for each pair of Timeline and Runtime instance that has served it. It
holds:

- the Timeline, the Node, and the Runtime instance;
- the ACP `sessionId`;
- the exact `cwd` and `additionalDirectories` the session was set up with;
- the MCP servers it was given, by reference and never with credentials;
- `syncedThrough`, the last Turn the Runtime session has seen;
- the session configuration options in effect;
- its state: `live`, `resumable`, or `lost`.

A Session record makes a Timeline stick to its Runtime instance. A session is
resumed only with its original `cwd`. A Timeline returning to a Runtime
instance resumes its `resumable` session and receives only the Turns after
`syncedThrough`. A record becomes `lost` only when the Runtime definitively
rejects the resume; then the Timeline is seeded into a new session. The Runtime
session is never Gnostic identity (ADR 0020).

## Session

A Session is one Runtime session of a Runtime instance. In Gnostic's vocabulary
it is described by its Session record.

## Timeline

A Timeline is Gnostic's primary primitive: a Gnostic-owned conversation, created
by a client on a Runtime instance and addressed by Gnostic operations. It is an
ordered list of Turns organized in spans, with at most one open span at a time,
and it can be handed to a different Runtime instance. Timeline identity is not
model context, execution, compaction, cache, or checkpoint state. A Runtime may
project a Timeline into its own state, but that projection cannot redefine or
erase Gnostic Timeline identity. A Timeline may have a parent Timeline (see
Subagent) and labels. Parallel work is modeled as child Timelines, never as
concurrent spans (ADR 0018, ADR 0020).

## Timeline label

A Timeline label is a key and value on a Timeline. The `experiment` key is
reserved: it marks a Timeline that belongs to an outer experiment (ADR 0020).

## Span

A span is the stretch of a Timeline served by one Session record. It records:

- its Session record, and through it the Runtime instance;
- the Runtime instance's ID, version, and launch fingerprint at its start;
- its first and last Turn;
- which Workspaces were delivered as roots;
- how it began: `new`, `resumed`, `seeded` (with the strategy and what was
  lost), or `forked`.

One Session record can serve several spans. Switching a Timeline to another
Runtime instance is an explicit Timeline operation that closes the open span
and opens a new one. A Turn never switches implicitly.

## Current operator

The current operator of a Timeline is the Runtime instance of its open span's
Session record. It replaces a stored, singular operator on the Timeline.

## Timeline record

The Timeline record is the Timeline's content. It is the ordered log of every
ACP v2 update the Runtime sent, as received, with its `_meta`, including kinds
Gnostic does not recognize, plus the prompts Gnostic sent. Folded entities
(messages, thoughts, tool calls, plans, compactions, terminal output) and the
latest session state are derived indexes that can be rebuilt from the log. It
is always stored on a Node with a state home, and kept in memory otherwise. It
is not the model's context: the Runtime decides what the model sees. It is a
separate store from the Turn event log, which stays digest-only (ADR 0020).

## Seeding

Seeding gives a Runtime session Turns it has not seen, through its prompt,
using a declared strategy. A full seed starts a new session from the whole
Timeline, after a switch of Runtime instance or a `lost` Session record. A
delta seed sends only the Turns after the Session record's `syncedThrough`.
Seeding into an ACP Runtime is lossy, and the record states the loss. A seed is
recorded as seeding metadata, never as a user Turn (ADR 0020).

## Subagent

A subagent is a child Timeline. It records its parent Timeline, the Turn that
spawned it, its Session record, and how it arose:

- `delegation`: Gnostic ran a Turn on another Runtime instance;
- `agentSubagent`: the Runtime exposed its own subagent session
  (`subagent_update`);
- `fork`: the session was forked.

## Project

A Project names where a Runtime session starts: its `cwd`. Every Session record
has one. The first Project kind is a **scratch Project**: an empty,
Gnostic-owned directory on the Runtime's Node, one per Session record, under a
random name with owner-only permissions, kept as long as the record is `live`
or `resumable`. Local and Git Projects are later kinds (ADR 0020).

## Placement

Placement decides how a Session's Project and Workspaces reach its Runtime.
The first strategy is a scratch Project with every Workspace delivered through
the Gnostic gateway, and no roots. A scratch directory is not a sandbox: a
Runtime's own tools can reach whatever its OS user can, until #631 isolates
Runtime instances (ADR 0020).

## Workspace

A Workspace is a discoverable capability resource. It is not inherently a
filesystem. A Workspace may expose filesystem tools, but its identity,
advertisement, attachment relationship, and capabilities are not determined by
a filesystem implementation. A Workspace reaches a Session as tools of the
Gnostic gateway. Delivery as a root is kept for a later placement strategy
(ADR 0018, ADR 0020).

## Root

A root is a Workspace delivered to a Session as a filesystem directory: the
Session's `cwd`, or one of its `additionalDirectories`. The Runtime's own file
and shell tools use it directly, so Gnostic's effective-status and permission
checks do not cover those calls. Root delivery is opt-in per attachment, never
used for an `unavailable` or read-only Workspace, and recorded per span. The
first placement strategy delivers no roots (ADR 0018, ADR 0020).

## Gnostic gateway

The Gnostic gateway is the MCP server Gnostic passes to a Session. It serves the
tools of the Workspaces attached to that Timeline, plus the network tools, and
reaches remote Workspaces over Axoloty. It applies Gnostic's effective-status
and permission checks to every call (ADR 0017). It uses MCP-over-ACP, HTTP, or
stdio, in that order, as the Runtime advertises them (ADR 0019); its stdio form
is a `gnostic` bridge process with a per-Session token (ADR 0020).

## Attachment intent

Attachment intent is the Node's durable statement that a Gnostic Timeline is
attached to a Workspace. Gnostic owns this intent and does not silently erase
it when a backend or resource is unavailable.

## Effective status

Effective status describes whether an intended Workspace attachment can be used
now, in a given delivery form (root or tools). The only values are `available`,
`unavailable`, and `unsupported`. Effective status is derived runtime state,
separate from attachment intent.

## Turn

A Turn is a Timeline-addressed, admitted Gnostic operation, and the unit of
handoff between Runtimes. It consists of a
Gnostic-owned **Turn envelope** and ACP v2 **Turn payloads**. Model and tool
execution semantics are owned by the Runtime. A Turn's prompt is accepted when
the Runtime inserts the user message (`messageId`), and the Turn ends when the
Runtime reports idle with a stop reason. Updates a Runtime sends outside a Turn
belong to the Timeline's open span, not to any Turn (ADR 0019).

## Turn envelope

The Turn envelope is the Gnostic-owned part of a Turn. It holds:

- the Timeline and the Session record that served the Turn;
- `clientTurnID`, admission, and replay;
- the sequence number;
- the terminal outcome and failure code;
- `protocolMajor`;
- the ACP version tag.

It also correlates permission requests and their replies. The `clientTurnID`
conflict check hashes RFC 8785 canonical JSON of the prompt content blocks
plus the ACP version tag (ADR 0018).

## Turn payload

A Turn payload is ACP content carried verbatim inside the envelope: prompt
content blocks in the request, and session update objects in the stream.
Gnostic interprets only the fields its envelope duties need, and forwards
unknown update kinds unchanged. Content above a Node's advertised threshold
travels as a resource link (ADR 0018).

## Capability

Gnostic defines no capability names of its own (ADR 0020). A Runtime
instance's capabilities are its Runtime's ACP `initialize` capabilities,
advertised verbatim as discovery data. The ACP adapter reads them where the
protocol requires it.

## protocol major

`protocolMajor` identifies the incompatible Gnostic network contract carried by
an advertisement, request, result, stream, or replay update. A Node publishes
one major, and every direct operation revalidates compatibility.

## Regime

A Regime is the configuration a Run uses: its Runtime instance, session
configuration options, placement, and Workspaces. Comparing Regimes, including
two that differ only in Runtime instance, is a primary use of Gnostic. A Regime
is a vocabulary term and a Run record field, not a stored primitive (ADR 0020).

## Module

A Module is a compiled-in, statically selected experiment or capability that
extends a Regime. Every Module has an entry in the module registry with an
owning issue and a lifecycle status (`incubating`, `gated`, `promoted`,
`parked`, or `archived`). A Module has one of two layers (ADR 0017).

## Outer module

An outer module is an outer experiment: a Gnostic consumer that works with every
Runtime. It uses Gnostic's client surface to set up its test, and presents as
special Workspaces (its tools) and as Timelines labelled `experiment`. It is not
a host hook (ADR 0020).

## Inner module

An inner module is an inner experiment that needs the model loop, such as
context projection, compaction inside a session, or executable context. Each
is a Native Runtime, and its settings are that Runtime's session configuration
options. Atlas is an inner module (ADR 0020).

## Run

A Run is one execution of a scenario under one Regime. It produces a trace and
a result record that name the Regime and the Module versions used.

## Turn event log

A Turn event log is the append-only, crash-safe record of one identified
Turn's bounded updates. Gnostic owns one shared log primitive in the kernel;
a restarted store replays the valid prefix and truncates a torn tail.
Durability is opt-in, so a serve without a configured state directory keeps its
in-memory ledger. The log stores bounded update payloads and a prompt digest,
never prompt text. The durable log is bounded by size: once it exceeds
`maxJournalBytes`, the store replaces it with one checkpoint per retained Turn,
which preserves the recovered ledger.

## Harness vocabulary

These terms belong to inner modules, which are Native Runtimes
(ADR 0017, ADR 0018, ADR 0020). They are not Gnostic primitives, and Gnostic-owned
contracts do not use them.

### Atlas

Atlas is the optional continuity and context architecture that supersedes
Narrative. It is an inner module, delivered as a Native Runtime. Generic Gnostic
identity and routing do not depend on it.

### Image

An Image is a persistent executable context file: plain model-readable
context that an inner module (Ouroboros) runs as its process image. Its source is
the model's context, not code. Harness types use the term Image. The
`.agent` file suffix and the `run-agent`, `spawn-agent`, and `exec-agent`
host-call names remain model-facing surface until a separate decision renames
them.

### Image invocation

An Image invocation is one run of a pinned Image revision with an ephemeral
input. It starts from a fresh context and does not carry a backend transcript
from an earlier invocation. Invocation input is not persisted unless the Image
itself writes it.

## Deprecated terms

These terms remain in older records and in code that has not yet migrated. Do
not use them in new Gnostic-owned identity, contracts, or documentation. A
deprecated term can still name working code: deprecation does not mean the
code or its tests are obsolete. Remove them only through the owning issue.

| Deprecated term | Use instead | Why (decision) |
| --- | --- | --- |
| Positronic Backend | Native Runtime | In-process Ascendant Backends are being retired (#611); PositronicKit will run only behind ACP (ADR 0017). |
| Backend kind `positronic`, backend kind `letta` | A Runtime instance of an ACP or Native Runtime | One backend boundary (ADR 0017; ADR 0010 is superseded). Both kinds stay valid until #611. |
| Backend transcript (as Timeline history) | Timeline record | History that crossed the boundary is Gnostic-owned; model context stays backend-owned (ADR 0017). |
| Timeline runtime repository (`FileTimelineRuntimeRepository`) | Timeline record | Superseded with ADR 0015 once the in-process backend is removed. |
| Backend envelope model keys (`provider`, `endpoint`, `model`, `utilityModel`, `fastModel`, `apiKey`) | Session configuration options of the Runtime instance | Model choice belongs to the agent and is set through ACP session config options. |
| `extensions` (Positronic extension selection) | An outer experiment, or a Native Runtime's session configuration for inner modules | Modules have two layers (ADR 0017). |
| Positronic contribution (`PositronicContribution`) | The Native Runtime contract (#609) | It moves into a Native Runtime (ADR 0020). |
| Backend hook, as a carrier for Modules in the host | Outer module (a Gnostic consumer), or inner module (a Native Runtime) | ADR 0013's hook rule is split by layer (ADR 0017). |
| Narrative | Atlas | Superseded earlier (ADR 0004). |
| Ascendant | Timeline and Runtime instance | No Agent-like primitive remains (ADR 0018, ADR 0020). Code, wire, and manifest drop it with #629. |
| Ascendant definition | Runtime instance defaults | ADR 0020, O1. |
| Ascendant Backend, Agent session | Runtime, Session record | ADR 0018, ADR 0020. |
| Ascendant private Timeline, Ascendant default Timeline | A Timeline created by the client | Agents hold no Timelines (ADR 0018, Q2). |
| `operatingAscendantID` | Current operator (the Runtime instance of the open span) | Timelines are sequences of spans (ADR 0018). |
| `AscendantTurnUpdateKind` (eight kinds and status vocabularies), `turn.text` capability | Turn payloads (ACP session updates) in the Turn envelope | Gnostic no longer re-encodes ACP (ADR 0018, #629). |
| Bounded legacy Agent terminology | Runtime and Timeline definitions | Gnostic owns no "Agent" term (ADR 0020). |
| Atlas, Image, Image invocation (as Gnostic primitives) | Harness vocabulary | Inner-module terms, not Gnostic primitives (ADR 0018). |
| `session/load`, "loaded" span | `session/resume` with `replayFrom`, "resumed" span | ACP v2 is the protocol baseline (ADR 0019). |
| Agent (Gnostic-owned), Agent definition | Timeline and Runtime instance; Runtime instance defaults | A harness carries its own identity and instructions (ADR 0020). |
| Gnostic harness agent | Native Runtime | Each inner experiment is its own Native Runtime (ADR 0020). |
| Gnostic interoperability capability (`AscendantInteroperabilityCapability`, `GnosticCapability`), backend optional capability | The Runtime instance's ACP `initialize` capabilities, as discovery data | Gnostic defines no capability names (ADR 0020). Removed with #629. |
| `ACPProfile`, `gnostic acp profiles` | Runtime instances and their Timelines | ADR 0020, O7. |
