# Gnostic domain constitution

This document is the canonical vocabulary for Gnostic. The relationships below
are Gnostic-owned unless a definition explicitly assigns ownership to a
backend.

## Node

A Node is one Gnostic host. It publishes one `protocolMajor`, launches the
Runtimes of the Agents it operates, and may operate several Agents.

## Agent

An Agent is a named, advertised, addressable configuration that binds one
Runtime to a Regime. Clients discover Agents on the network and address Turns
to them, and Regimes are compared across them. An Agent's UUID is Gnostic
identity.

An Agent holds configuration only: no memory and no Timelines of its own.
Continuity belongs to Timelines. Changing an Agent's Runtime makes a different
Agent. "Agent" is the Gnostic-owned term, and the ACP program it runs on is its
Runtime. Code for the ACP protocol role keeps the ACP SDK's names, or an `ACP`
prefix (ADR 0018).

Until #629 lands, code, wire operations, the manifest, and the CLI still call
an Agent an **Ascendant**.

## Agent definition

An Agent definition is the Node's configuration for one Agent, and it is that
Agent's Regime. It holds:

- its identity;
- its Runtime;
- its instructions;
- its session configuration, which is where model, mode, and inner-module
  settings are set;
- its permission policy;
- its outer modules;
- its default Workspace attachments, including which ones may be delivered as
  roots.

Instructions reach the Runtime as the ACP system prompt when the Runtime
advertises it, and otherwise through a fallback declared per Agent
(ADR 0017, ADR 0018).

## Runtime

A Runtime is the ACP harness an Agent runs on, for example Claude Agent, Codex,
opencode, or a harness built in this repository. It is a value, not Gnostic
identity. It is identified by its ACP registry ID when one exists. Otherwise it
is identified by a launch fingerprint over the command, the arguments, and the
environment variable names, never their values or any secret.

A Runtime owns model and tool semantics, model context, compaction, caches, and
its own lifecycle. One Runtime can back many Agents. Gnostic connects and
orchestrates Runtimes and depends on none of them. An Agent's capabilities
derive from its Runtime's ACP `initialize` result plus what Gnostic adds
(ADR 0018).

Until #611 retires them, the in-process `positronic` and `letta` backend kinds
remain valid.

## Gnostic harness agent

The Gnostic harness agent is a Runtime this repository builds on PositronicKit.
Gnostic hosts it like any other Runtime. In the target state, it and any other
harness built here are the only parts of Gnostic allowed to depend on
PositronicKit. Until #604 and #611 land, a transitional allow-list in ADR 0017
names the other targets that still do. PositronicKit types such as
`AgentInstance` and `Thread` stay private to it.

## Session

A Session is one ACP session of a Runtime. It serves one or more spans of one
Timeline: a resumed or loaded span reuses an earlier Session. It is
backend-private state and never Gnostic identity. Losing it loses no
Gnostic-owned state.

## Timeline

A Timeline is a Gnostic-owned conversation, addressed by Gnostic operations. It
is a sequence of spans, with at most one open span at a time. Timeline identity
is not model context, execution, compaction, cache, or checkpoint state. A
Session may project a Timeline into backend-private state, but that projection
cannot redefine or erase Gnostic Timeline identity. A Timeline may have a
parent Timeline (see Subagent). Parallel work is modeled as child Timelines,
never as concurrent spans (ADR 0018).

## Span

A span is the stretch of a Timeline served by one Session of one Agent. It
records:

- its Agent;
- its Runtime and Session;
- its first and last Turn;
- which Workspaces were delivered as roots;
- how it began: `new`, `resumed`, `loaded`, `seeded` (with the strategy and what
  was lost), or `forked`.

Switching a Timeline to another Agent is an explicit Timeline operation that
closes the open span and opens a new one. A Turn never switches implicitly.

## Current operator

The current operator of a Timeline is the Agent of its open span. It replaces a
stored, singular operating Agent on the Timeline.

## Timeline record

The Timeline record is Gnostic's durable account of what crossed the Runtime
boundary on one Timeline, organized by span. It holds:

- the ACP payloads Gnostic sent and received, as received;
- its spans and their Sessions;
- each seeding boundary and what it lost.

It is not the model's context: the Runtime decides what the model sees. It is a
separate store from the Turn event log, which stays digest-only. The record is
opt-in under the state home, and it is the only place Turn content is stored
at rest (ADR 0017, ADR 0018).

## Seeding

Seeding starts a new Session for an existing Timeline from its Timeline record,
using a declared strategy. Gnostic seeds when the Runtime cannot resume or load
the old Session, or when the Timeline switches Agent. Seeding is lossy, and the
record states the loss.

## Subagent

A subagent is a child Timeline. It records its parent Timeline, the Turn that
spawned it, its operating Agent, and how it arose:

- `delegation`: Gnostic ran a Turn on another Agent;
- `agentSubagent`: the Runtime exposed its own subagent session;
- `fork`: the Session was forked.

## Workspace

A Workspace is a discoverable capability resource. It is not inherently a
filesystem. A Workspace may expose filesystem tools, but its identity,
advertisement, attachment relationship, and capabilities are not determined by
a filesystem implementation. A Workspace reaches a Session in one of two
delivery forms (ADR 0018):

- as a **root**;
- as **tools** of the Gnostic gateway.

A remote filesystem Workspace is always delivered as tools.

## Root

A root is a Workspace delivered to a Session as a filesystem directory: the
Session's `cwd` (the primary root), or one of its `additionalDirectories`. The
Runtime's own file and shell tools use it directly, so Gnostic's effective-status
and permission checks do not cover those calls. Root delivery is therefore
opt-in per attachment, never used for an `unavailable` or read-only Workspace,
and recorded per span. With no root attached, `cwd` is a Gnostic-owned scratch
directory for the Timeline (ADR 0018).

## Gnostic gateway

The Gnostic gateway is the MCP server Gnostic passes to a Session. It serves the
tools of the Workspaces attached to that Timeline that are not delivered as
roots, plus the network tools. It applies Gnostic's effective-status and
permission checks to every call (ADR 0017).

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

A Turn is a Timeline-addressed, admitted Gnostic operation. It consists of a
Gnostic-owned **Turn envelope** and ACP **Turn payloads**. Model and tool
execution semantics are owned by the Runtime.

## Turn envelope

The Turn envelope is the Gnostic-owned part of a Turn. It holds:

- the Timeline and the addressed Agent;
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

A capability is a named, versioned behavior that a Node or Agent can consume or
advertise. Interoperability capabilities are selected by `protocolMajor` and
capability name, never by Runtime assumptions. An Agent's capabilities derive
from its Runtime's ACP `initialize` result plus what Gnostic adds.

## protocol major

`protocolMajor` identifies the incompatible Gnostic network contract carried by
an advertisement, request, result, stream, or replay update. A Node publishes
one major, and every direct operation revalidates compatibility.

## Regime

A Regime is the operating configuration of an Agent. It is identical to the
Agent definition: Runtime, instructions, session configuration, permission
policy, outer modules, and default attachments. Comparing Regimes, including
two Agents that differ only in Runtime, is a primary use of Gnostic. A Regime is
a vocabulary term and a Run record field (ADR 0018).

## Module

A Module is a compiled-in, statically selected experiment or capability that
extends a Regime. Every Module has an entry in the module registry with an
owning issue and a lifecycle status (`incubating`, `gated`, `promoted`,
`parked`, or `archived`). A Module has one of two layers (ADR 0017).

## Outer module

An outer module runs in the Gnostic host and works with every Runtime. Examples
are Gnostic gateway tool surfaces, seeding and session rotation, prompt
shaping, and measurement.

## Inner module

An inner module needs the model loop. Examples are context projection,
compaction inside a session, cache-aware prompt shaping, and executable
context. It runs only inside the Gnostic harness agent, and its settings are
exposed as that agent's session configuration. Atlas is an inner module.

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

These terms belong to the inner modules of harnesses built in this repository
(ADR 0017, ADR 0018). They are not Gnostic primitives, and Gnostic-owned
contracts do not use them.

### Atlas

Atlas is the optional continuity and context architecture that supersedes
Narrative. It is an inner module of the Gnostic harness agent. Generic Gnostic
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
| Positronic Backend | Gnostic harness agent | In-process Ascendant Backends are being retired (#611); PositronicKit will run only behind ACP (ADR 0017). |
| Backend kind `positronic`, backend kind `letta` | `acp-client` with an Agent definition | One backend boundary (ADR 0017; ADR 0010 is superseded). Both kinds stay valid until #611. |
| Backend transcript (as Timeline history) | Timeline record | History that crossed the boundary is Gnostic-owned; model context stays backend-owned (ADR 0017). |
| Timeline runtime repository (`FileTimelineRuntimeRepository`) | Timeline record | Superseded with ADR 0015 once the in-process backend is removed. |
| Backend envelope model keys (`provider`, `endpoint`, `model`, `utilityModel`, `fastModel`, `apiKey`) | Session configuration in the Agent definition | Model choice belongs to the agent and is set through ACP session config options. |
| `extensions` (Positronic extension selection) | Outer module selection, or the harness agent's session configuration for inner modules | Modules have two layers (ADR 0017). |
| Positronic contribution (`PositronicContribution`) | The harness agent's inner module interface (defined by #609) | It moves into the Gnostic harness agent. |
| Backend hook, as a carrier for Modules in the host | Outer module (host hook points defined by #612), or inner module | ADR 0013's hook rule is split by layer (ADR 0017). |
| Narrative | Atlas | Superseded earlier (ADR 0004). |
| Ascendant | Agent | One Gnostic-owned primitive (ADR 0018). Code, wire, and manifest rename with #629. |
| Ascendant definition | Agent definition (which is the Agent's Regime) | ADR 0018 §1. |
| Ascendant Backend, Agent session | Runtime, Session | The ACP harness is a value, and its session is external state (ADR 0018). |
| Ascendant private Timeline, Ascendant default Timeline | A Timeline created by the client | Agents hold no Timelines (ADR 0018, Q2). |
| `operatingAscendantID` | Current operator (the Agent of the open span) | Timelines are sequences of spans (ADR 0018). |
| `AscendantTurnUpdateKind` (eight kinds and status vocabularies), `turn.text` capability | Turn payloads (ACP session updates) in the Turn envelope | Gnostic no longer re-encodes ACP (ADR 0018, #629). |
| Bounded legacy Agent terminology | Agent and Runtime definitions | "Agent" now has one Gnostic-owned meaning (ADR 0018). |
| Atlas, Image, Image invocation (as Gnostic primitives) | Harness vocabulary | Inner-module terms, not Gnostic primitives (ADR 0018). |
