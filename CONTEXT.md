# Gnostic domain constitution

This document is the canonical vocabulary for Gnostic. The relationships below
are Gnostic-owned unless a definition explicitly assigns ownership to a
backend.

## Node

A Node is one Gnostic host. It publishes one `protocolMajor` and may operate
several Ascendants.

## Ascendant

An Ascendant is a stable Gnostic logical agent identity. At startup an
Ascendant binds to one Ascendant Backend. Its UUID is Gnostic identity and may
survive a backend change made while the Node is stopped.

## Ascendant definition

An Ascendant definition is the Node's configuration for one Ascendant. It
holds:

- its identity;
- how to launch its ACP agent;
- its instructions;
- its session configuration, which is where model and mode are set;
- its permission policy;
- its default Workspace attachments.

Instructions reach the agent as the ACP system prompt when the agent
advertises it, and otherwise through a fallback declared per Ascendant
(ADR 0017).

## Ascendant Backend

An Ascendant Backend owns execution for one Ascendant: model and tool
semantics, model context, compaction, caches, checkpoints, and backend-native
lifecycle. Every Ascendant Backend is an ACP agent reached over ACP
(ADR 0017). Gnostic owns the host boundary, identity, Turn admission,
permission mediation, and the Timeline record around it.

## Gnostic harness agent

The Gnostic harness agent is the ACP agent this repository builds on
PositronicKit. Gnostic hosts it as an ordinary Ascendant Backend. It is the
only place inner modules run, and the only part of Gnostic allowed to depend
on PositronicKit (ADR 0017). PositronicKit types such as `AgentInstance` and
`Thread` stay private to it.

## Agent session

An agent session is one ACP session that an Ascendant Backend holds for a
Timeline. It is a disposable projection of the Timeline. Losing it loses no
Gnostic-owned state. A Timeline continues in a new agent session by resuming
or loading the old one, or by seeding a new one from the Timeline record.

## Timeline

A Timeline is Gnostic-owned identity and relationship state addressed by
Gnostic operations. Timeline identity is not model context, execution,
compaction, cache, or checkpoint state. An agent session may project a Timeline
into backend-private state, but that projection cannot redefine or erase
Gnostic Timeline identity. A Timeline may have a parent Timeline (see
Subagent).

## Timeline record

The Timeline record is Gnostic's durable account of what crossed the backend
boundary on one Timeline. It holds:

- the prompts Gnostic sent;
- the normalized updates the agent returned;
- which agent sessions served which span;
- each seeding boundary and what it lost.

It is not the model's context: the backend decides what the model sees. The
record is opt-in under the state home (ADR 0017).

## Seeding

Seeding starts a new agent session for an existing Timeline from its Timeline
record, using a declared strategy, when the agent cannot resume or load the
old session. Seeding is lossy, and the record states the loss.

## Subagent

A subagent is a child Timeline. It records its parent Timeline, the Turn that
spawned it, its operating Ascendant, and how it arose:

- `delegation`: Gnostic ran a Turn on another Ascendant;
- `agentSubagent`: the agent exposed its own subagent session;
- `fork`: the session was forked.

## Workspace

A Workspace is a discoverable capability resource. It is not inherently a
filesystem. A Workspace may expose filesystem tools, but its identity,
advertisement, attachment relationship, and capabilities are not determined
by a filesystem implementation. Workspaces reach agents as tools of the
Gnostic gateway.

## Gnostic gateway

The Gnostic gateway is the MCP server Gnostic passes to an agent session. It
serves the tools of the Workspaces attached to that Timeline, plus the network
tools, and applies Gnostic's effective-status and permission checks to every
call (ADR 0017).

## Attachment intent

Attachment intent is the Node's durable statement that a Gnostic Timeline is
attached to a Workspace. Gnostic owns this intent and does not silently erase
it when a backend or resource is unavailable.

## Effective status

Effective status describes whether an intended Workspace attachment can be
used now. The only values are `available`, `unavailable`, and `unsupported`.
Effective status is derived runtime state, separate from attachment intent.

## Turn

A Turn is a Timeline-addressed, admitted Gnostic operation. Its network and
host envelope are Gnostic-owned; model and tool execution semantics are owned
by the Ascendant Backend.

## Capability

A capability is a named, versioned behavior that a Node or Ascendant instance
can consume or advertise. Interoperability capabilities are selected by
`protocolMajor` and capability name, never by backend-kind assumptions.

## protocol major

`protocolMajor` identifies the incompatible Gnostic network contract carried by
an advertisement, request, result, stream, or replay update. A Node publishes
one major, and every direct operation revalidates compatibility.

## Atlas

Atlas is the optional continuity and context architecture that supersedes
Narrative. It is an inner module of the Gnostic harness agent (ADR 0017).
Generic Gnostic identity and routing do not depend on it.

## Regime

A Regime is the operating configuration an Ascendant runs under:

- its agent;
- that agent's session configuration;
- its selected outer modules;
- its policies.

Comparing Regimes, including across third-party agents and the Gnostic harness
agent, is a primary use of Gnostic. A Regime is a vocabulary term and a Run
record field; it is not yet a named Node manifest object.

## Module

A Module is a compiled-in, statically selected experiment or capability that
extends a Regime. Every Module has an entry in the module registry with an
owning issue and a lifecycle status (`incubating`, `gated`, `promoted`,
`parked`, or `archived`). A Module has one of two layers (ADR 0017).

## Outer module

An outer module runs in the Gnostic host and works with every agent. Examples
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

## Image

An Image is a persistent executable context file: plain model-readable
context that an inner module (Ouroboros) runs as its process image. Its source is
the model's context, not code. Gnostic-owned types use the term Image. The
`.agent` file suffix and the `run-agent`, `spawn-agent`, and `exec-agent`
host-call names remain model-facing surface until a separate decision renames
them.

## Image invocation

An Image invocation is one run of a pinned Image revision with an ephemeral
input. It starts from a fresh context and does not carry a backend transcript
from an earlier invocation. Invocation input is not persisted unless the Image
itself writes it.

## Bounded legacy Agent terminology

`Agent` is retained only when naming an external protocol boundary, an
upstream/backend-native type, or historical data that has not yet been
migrated. New Gnostic-owned identity, lifecycle, and wire terminology uses
Ascendant. PositronicKit's `AgentInstance` remains backend-private and is not a
counterexample to this rule.

## Deprecated terms

These terms remain in older records and in code that has not yet migrated. Do
not use them in new Gnostic-owned identity, contracts, or documentation.

| Deprecated term | Use instead | Why (decision) |
| --- | --- | --- |
| Positronic Backend | Gnostic harness agent | In-process Ascendant Backends are retired; PositronicKit runs only behind ACP (ADR 0017). |
| Backend kind `positronic`, backend kind `letta` | `acp-client` with an Ascendant definition | One backend boundary (ADR 0017; ADR 0010 is superseded). |
| Backend transcript (as Timeline history) | Timeline record | History that crossed the boundary is Gnostic-owned; model context stays backend-owned (ADR 0017). |
| Timeline runtime repository (`FileTimelineRuntimeRepository`) | Timeline record | Superseded with ADR 0015 once the in-process backend is removed. |
| Backend envelope model keys (`provider`, `endpoint`, `model`, `utilityModel`, `fastModel`, `apiKey`) | Session configuration in the Ascendant definition | Model choice belongs to the agent and is set through ACP session config options. |
| `extensions` (Positronic extension selection) | Outer module selection, or the harness agent's session configuration for inner modules | Modules have two layers (ADR 0017). |
| Positronic contribution (`PositronicContribution`) | Inner module hook | It moves into the Gnostic harness agent. |
| Backend hook, as a carrier for Modules in the host | Outer module hook point, or inner module | ADR 0013's hook rule is split by layer (ADR 0017). |
| Narrative | Atlas | Superseded earlier (ADR 0004). |
