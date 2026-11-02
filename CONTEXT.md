# Gnostic domain constitution

This document is the canonical vocabulary for Gnostic. The relationships below
are Gnostic-owned unless a definition explicitly assigns ownership to a
backend.

## Node

A Node is one Gnostic host. It publishes one `protocolMajor`, owns the Timelines
created there, hosts Runtime instances, and advertises them, its Timelines, and
its Workspaces on Axoloty. A Timeline keeps its owning Node for its lifetime.
Requests for a remote Timeline route to its owner, and requests for a Runtime
instance route to its hosting Node (ADR 0021).

## Runtime

A Runtime is a kind of harness, for example Claude Agent, Codex, or opencode.
It is not Gnostic identity. A Runtime instance is one configured install of a
Runtime kind on one Node. In v0.5, every Runtime uses the ACP v2 session
contract over stdio. A Runtime kind is identified by its ACP registry ID, or as
`local-command` with a launch fingerprint over the command, the arguments, and
the environment variable names, never their values or any secret.

A Runtime owns its identity and instructions (its own system prompt), model and
tool semantics, model context, compaction, caches, and its own lifecycle.
Gnostic connects to and orchestrates Runtimes. Every Runtime implements the
ACP v2 session surface without its JSON-RPC framing inside Gnostic (ADR 0019,
ADR 0021). Gnostic has no separate in-process Runtime kind.

## ACP Runtime

An ACP Runtime is a harness process that Gnostic controls through ACP v2
JSON-RPC over stdio. A Runtime process may be external or built in this
repository. Both use the same process boundary (ADR 0021).

## Reference Runtime

The reference Runtime is the standalone PositronicKit 7 implementation shipped
with Gnostic. It is an ACP Runtime process supervised by a Gnostic Node. It
does not join Axoloty or connect to MQTT, and PositronicKit types stay private
to its executable (ADR 0021).

## Runtime instance

A Runtime instance is one configured install of a Runtime kind on one Node. It
owns:

- its install and pinned version, or an executable override;
- its arguments, environment, and secrets;
- its authentication state;
- its advertised catalog of models and session config options;
- its default session configuration options and its permission policy;
- its process and its ACP v2 capabilities.

Clients choose a Runtime instance when they create a Timeline, and may override
its session configuration options for that Timeline. Two instances never share
mutable state or credentials. A Runtime instance has a Node-scoped ID. Its Node
advertises it together with its Runtime's ACP `initialize` capabilities,
verbatim, as discovery data. Each span records the instance's ID, version, and
launch fingerprint at its start (ADR 0018, ADR 0020, ADR 0021, #631).

The v0.5 release removes the in-process `positronic` and `letta` backend kinds
(ADR 0021, #611).

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
- its state: `live`, `resumable`, `lost`, or `ambiguous`.

A Session record makes a Timeline stick to its Runtime instance. A session is
resumed only with its original `cwd`. A Timeline returning to a Runtime
instance may resume its `resumable` session with its original `cwd`. A record
becomes `lost` only when the Runtime definitively rejects resume or confirms
deletion. A transport or process failure that leaves the result unclear marks
the record `ambiguous`. Gnostic does not issue a new prompt or claim continuity
from that state. A Project change opens a new Session record on the same
Timeline without synthetic context seeding. The Runtime session is never
Gnostic identity (ADR 0021).

## Session

A Session is one ACP session of a Runtime instance. In Gnostic's vocabulary it
is described by its Session record. A Session change does not change Timeline
identity or prove that model context continued.

## Timeline

A Timeline is Gnostic's primary work identity. A client creates it on one
owning Node and selects a Runtime instance to serve it. It is an ordered list
of Turns organized in spans, with at most one open span at a time. It has one
authoritative durable journal on its owning Node. Timeline identity is not
model context, execution, compaction, cache, or checkpoint state. A Runtime may
project a Timeline into its own state, but that projection cannot redefine or
erase Gnostic Timeline identity. A distinct Turn cannot start while another
foreground Turn is active. Cross-Runtime context handoff is deferred (ADR
0021).

## Timeline label

A Timeline label is a key and value on a Timeline. The `experiment` key is
reserved: it marks a Timeline that belongs to an outer experiment (ADR 0020).

## Span

A span is the stretch of a Timeline served by one Session record. It records:

- its Session record, and through it the Runtime instance;
- the Runtime instance's ID, version, and launch fingerprint at its start;
- its first and last Turn;
- its Project and attached Workspaces;
- how it began: `new`, `resumed`, or `projectChanged`.

One Session record can serve several spans. Switching a Timeline to another
Runtime instance is an explicit Timeline operation that closes the open span
and opens a new one. A Turn never switches implicitly. Changing the Project
`cwd` opens a new Session record and span on the same Timeline (ADR 0021).

## Current operator

The current operator of a Timeline is the Runtime instance of its open span's
Session record. It replaces a stored, singular operator on the Timeline.

## Timeline record

The Timeline record is the Timeline's content. It is the durable, ordered
journal of Gnostic orchestration events and every ACP v2 update the Runtime
sent, as received, with its `_meta`, including kinds Gnostic does not recognize.
Each event has a format version, replay epoch, monotonic sequence number,
timestamp, and causal span. Folded entities and the latest Session view are
derived indexes that can be rebuilt from the journal. The owning Node syncs
events before dispatch or forwarding. A torn tail is truncated, a corrupt
committed prefix quarantines the Timeline as read-only, and an unknown format
version is rejected. A Timeline without a writable journal is not admitted as
a Timeline in v0.5. The record is not the model's context. It is separate from
the Turn event log, which stays digest-only (ADR 0021).

## Seeding

Seeding would give a Runtime session Turns it has not seen through its prompt.
Gnostic does not seed a new Session from the Timeline in v0.5. Cross-Runtime
seeding is deferred because ACP does not define history import and Timeline
events do not represent the model's full context (ADR 0021).

## Subagent

A subagent is a possible later form of child Timeline. Automatic subagent
lineage is deferred in v0.5 (ADR 0021). A later implementation may record the
parent Timeline, spawning Turn, Session record, and how the child arose:

- `delegation`: Gnostic ran a Turn on another Runtime instance;
- `agentSubagent`: the Runtime exposed its own subagent session
  (`subagent_update`);
- `fork`: the session was forked.

## Project

A Project names where a Runtime session starts: its `cwd`. Every Session record
has one. v0.5 supports a local Project at an operator-selected path or a clean,
Gnostic-managed scratch Project on the Runtime's Node. A Project change starts
a new Session record on the same Timeline. Neither Project kind is a filesystem
sandbox (ADR 0021).

## Placement

Placement decides how a Session's Project and Workspaces reach its Runtime.
The Project supplies `cwd`, and attached Workspaces are delivered as tools
through the Gnostic gateway. The Runtime's own tools can reach any path allowed
to its operating-system user. Gnostic does not claim filesystem isolation
(ADR 0021).

## Workspace

A Workspace is a discoverable capability resource. It is not inherently a
filesystem. A Workspace may expose filesystem tools, but its identity,
advertisement, attachment relationship, and capabilities are not determined by
a filesystem implementation. In v0.5, a Workspace reaches a Session only as
tools of the Gnostic gateway. Root delivery is deferred (ADR 0021).

## Root

A root is a Workspace directory delivered to a Session as `cwd` or an
`additionalDirectories` entry. The Runtime's own file and shell tools use it
directly, so Gnostic's Workspace checks do not cover those calls. v0.5 does not
deliver Workspace roots. A Project supplies `cwd`; attached Workspaces use the
gateway (ADR 0021).

## Gnostic gateway

The Gnostic gateway is the MCP server Gnostic passes to a Session. It serves the
tools of the Workspaces attached to that Timeline and routes remote Workspace
calls over Axoloty. The gateway checks Timeline attachment and permission for
each call. The Workspace-owning Node checks the current Timeline attachment,
effective status, and tool membership before it invokes the provider (ADR 0021).
Transport selection follows the MCP-over-ACP, HTTP, then stdio order in ADR 0019
and uses only a transport the Runtime advertises. The ACP backend currently
provides an authenticated loopback HTTP server when the Runtime advertises
HTTP; it sends the endpoint and a per-Session bearer token in the ACP MCP server
configuration.

## Attachment intent

Attachment intent is the Node's durable statement that a Gnostic Timeline is
attached to a Workspace. Gnostic owns this intent and does not silently erase
it when a backend or resource is unavailable.

## Effective status

Effective status describes whether an intended Workspace attachment can be used
now through the Gnostic gateway. The only values are `available`, `unavailable`,
and `unsupported`. Effective status is derived runtime state, separate from
attachment intent.

## Turn

A Turn is a Timeline-addressed, admitted Gnostic operation. It consists of a
Gnostic-owned Turn envelope and ACP v2 prompt and update payloads. Model and
tool execution semantics belong to the Runtime. Gnostic allows at most one
active foreground Turn per Timeline. A distinct request while a Turn is active
is rejected before `session/prompt`; an identical `clientTurnID` retry returns
the existing Turn. A Turn is inserted when the Runtime accepts the user message
(`messageId`) and ends on the next `idle` update with a stop reason. Updates
outside a Turn belong to the Timeline's open span (ADR 0021).

## Turn envelope

The Turn envelope is the Gnostic-owned part of a Turn. It holds:

- the Timeline and the Session record that served the Turn;
- `clientTurnID`, admission, and replay;
- the active-Turn decision and prompt digest;
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
protocol requires it (ADR 0021).

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
`parked`, or `archived`). A Module may be an outer consumer or an inner
Runtime experiment. No research Module is required to build or run the v0.5
host (ADR 0021).

## Outer module

An outer module is an outer experiment: a Gnostic consumer that works with every
Runtime. It uses Gnostic's client surface to set up its test, and presents as
special Workspaces (its tools) and as Timelines labelled `experiment`. It is not
a host hook (ADR 0020).

## Inner module

An inner module is a research experiment that needs a model loop, such as
context projection or compaction. It is not part of the v0.5 host. A later
implementation may run it as an independent ACP Runtime process. Atlas is a
parked design reference (ADR 0021).

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

These terms belong to research designs, not to Gnostic identity or contracts.
Those designs are not required to build or run the v0.5 host (ADR 0021).

### Atlas

Atlas is an optional continuity and context architecture that supersedes
Narrative. It is a parked design reference. Gnostic identity and routing do not
depend on it.

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
| Positronic Backend | Standalone reference Runtime | The v0.5 host uses ACP processes and keeps PositronicKit in the separate reference Runtime executable (ADR 0021). |
| Backend kind `positronic`, backend kind `letta` | ACP Runtime instance | The in-process kinds are removed in v0.5 (#611). |
| Backend transcript (as Timeline history) | Timeline record | History that crossed the boundary is Gnostic-owned; model context stays backend-owned (ADR 0017). |
| Timeline runtime repository (`FileTimelineRuntimeRepository`) | Timeline record | Superseded with ADR 0015 once the in-process backend is removed. |
| Backend envelope model keys (`provider`, `endpoint`, `model`, `utilityModel`, `fastModel`, `apiKey`) | Session configuration options of the Runtime instance | Model choice belongs to the Runtime and is set through ACP session config options. |
| `extensions` (Positronic extension selection) | An outer consumer or a separate ACP Runtime | Research code is not required by the host (ADR 0021). |
| Positronic contribution (`PositronicContribution`) | ACP Runtime process | The reference Runtime uses the ACP v2 stdio boundary (#609, ADR 0021). |
| Backend hook, as a carrier for Modules in the host | Outer consumer or separate ACP Runtime | Research code has no mandatory host integration (ADR 0021). |
| Narrative | Atlas | Superseded earlier (ADR 0004). |
| Ascendant | Timeline and Runtime instance | No Agent-like primitive remains (ADR 0020, ADR 0021). Code, wire, and manifest drop it with #629. |
| Ascendant definition | Runtime instance defaults | ADR 0020, O1. |
| Ascendant Backend, Agent session | ACP Runtime, Session record | ADR 0018, ADR 0020, ADR 0021. |
| Ascendant private Timeline, Ascendant default Timeline | A Timeline created by the client | Runtime instances do not own Timelines (ADR 0018, ADR 0021). |
| `operatingAscendantID` | Current operator (the Runtime instance of the open span) | Timelines are sequences of spans (ADR 0018). |
| `TurnUpdateKind` (eight kinds and status vocabularies), `turn.text` capability | Turn payloads (ACP session updates) in the Turn envelope | Gnostic no longer re-encodes ACP (ADR 0018, #629). |
| Bounded legacy Agent terminology | Runtime and Timeline definitions | Gnostic owns no "Agent" term (ADR 0020). |
| Atlas, Image, Image invocation (as Gnostic primitives) | Harness vocabulary | Inner-module terms, not Gnostic primitives (ADR 0018). |
| `session/load`, "loaded" span | `session/resume` with `replayFrom`, "resumed" span | ACP v2 is the protocol baseline (ADR 0019). |
| Agent (Gnostic-owned), Agent definition | Timeline and Runtime instance | A harness carries its own identity and instructions (ADR 0020, ADR 0021). |
| Native Runtime, special-Node Runtime | ACP Runtime process | Every Runtime uses ACP v2 over stdio; no separate in-process Runtime kind exists (ADR 0021). |
| Gnostic harness agent | Standalone reference Runtime | The reference Runtime is a separate ACP process, not a Gnostic Agent or special Node (ADR 0021). |
| Gnostic interoperability capability (`InteroperabilityCapability`, `GnosticCapability`), backend optional capability | The Runtime instance's ACP `initialize` capabilities, as discovery data | Gnostic defines no capability names (ADR 0020). Removed with #629. |
| `ACPProfile`, `gnostic acp profiles` | Runtime instances and their Timelines | ADR 0020, O7. |
