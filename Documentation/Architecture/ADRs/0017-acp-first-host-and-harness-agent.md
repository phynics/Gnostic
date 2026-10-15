# ADR 0017 — ACP-first host, the Gnostic harness agent, and the PositronicKit firewall

## Status

Accepted target architecture (2026-10-15). Owning issue:
[GNO-ACPF-001 #603](https://github.com/phynics/Gnostic/issues/603). Delivery is
tracked by [Epic #602](https://github.com/phynics/Gnostic/issues/602). Delivery
is checked by the [Epic #140](https://github.com/phynics/Gnostic/issues/140) and
[RESET-001 #145](https://github.com/phynics/Gnostic/issues/145) documentation
and architecture gates.

This record is a direction decision. It changes no code, dependency, manifest
shape, wire contract, or persistence format. Each consequence that does is
delivered by its own child issue of #602 and is review-required under
`AGENTS.md`.

This record amends:

- [ADR 0002](0002-gnostic-identity-vs-backend-state.md), because the Timeline
  record becomes Gnostic-owned state;
- [ADR 0004](0004-atlas-supersedes-narrative.md), because Atlas becomes an inner
  module of the harness agent;
- [ADR 0005](0005-core-positronic-dependency-boundary.md), because the
  PositronicKit boundary widens from `GnosticCore` to every host target;
- [ADR 0011](0011-external-acp-backends.md), because Workspaces now reach ACP
  agents;
- [ADR 0013](0013-experimentation-platform.md), because Modules gain two layers;
- [ADR 0016](0016-ouroboros-akasha-executor-placement.md), because the Positronic
  host of both experiments becomes the harness agent.

It supersedes:

- [ADR 0010](0010-letta-ascendant-backend-evaluation.md), because the Letta
  prototype is retired;
- [ADR 0015](0015-file-backed-timeline-runtime-repository.md), whose
  file-backed Positronic transcript store is replaced by the Gnostic-owned
  Timeline record. It remains in force until
  [#611](https://github.com/phynics/Gnostic/issues/611) removes the in-process
  backend.

## Context

Gnostic began as a host for PositronicKit agents. It has since gained two ACP
seams:

- `gnostic acp`, the frontend: Gnostic acts as an ACP agent for editors.
- `GnosticACPAscendant`, the backend (ADR 0011): an external ACP agent, such as
  Claude Agent, Codex, or opencode, operates an Ascendant.

Three facts now pull in the same direction.

1. **Experiments compared against Gnostic's own baseline prove little.** Gnostic
   exists to compare methods of tool organization, context management,
   continuity, and compaction (ADR 0013). The only baseline it can run today is
   its own Positronic backend. The ACP backend already runs the agents that
   people actually use.
2. **PositronicKit coupling sets the host's pace.** PositronicKit 7.0 reshapes
   storage, providers, and prompts
   ([#550](https://github.com/phynics/Gnostic/issues/550)). The 0.5.0 line
   waited on it ([#551](https://github.com/phynics/Gnostic/issues/551) decision
   D1), and the nightly against PositronicKit `main` fails
   ([#546](https://github.com/phynics/Gnostic/issues/546)). PositronicKit is
   imported by `GnosticPositronicBackend`, `GnosticPositronicAtlas`,
   `GnosticPositronicContext`, `GnosticHost`, `GnosticCLI`, and
   `GnosticACPFrontend` (for `AnyCodable` only). The kernel test target links
   the Positronic backend
   (`Tests/GnosticCoreTests/BackendArchitectureFitnessTests.swift`).
3. **ACP now covers most of what Gnostic needs.** The state of the
   specification on agent-client-protocol `main` (2026-10-14) is:

   | Surface | RFD stage | Gnostic use |
   | --- | --- | --- |
   | `session/new`, `session/load` with `mcpServers` (stdio required; HTTP and SSE by capability) | Stable v1 | Workspace delivery |
   | `session/list`, `session/resume`, `session/close`, session config options, `model_config` category, session usage | Completed | Continuity, Ascendant configuration, metering |
   | Client-Provided System Prompt | Draft | Ascendant instructions |
   | Subagent Sessions | Draft | Child Timelines for an agent's own subagents |
   | `session/fork` | Draft | Fork lineage |
   | MCP-over-ACP | Draft | Workspace delivery without a second process |
   | Proxy chains | Draft | Possible outer-module carrier |
   | v2: removal of client `fs/*` and `terminal/*`; one `session/resume` with replay | Active | Rule out client-side tool execution |

   ACP has no request field that supplies prior history to a new session.
   Only `session/load` replays the agent's own stored history.

The domain questions this record answers are where Timeline history lives, how
Workspaces reach agents, how subagents are modeled, what an Ascendant
definition contains, which experiments survive, and where PositronicKit may
appear.

## Decision

### 1. ACP is the Ascendant Backend boundary

Every Ascendant Backend is an ACP agent, reached by the `acp-client` kind
(ADR 0011). The in-process `positronic` and `letta` kinds are retired once the
harness agent (section 6) reaches parity; [#611](https://github.com/phynics/Gnostic/issues/611)
tracks the removal. ADR 0011's ownership invariant stands unchanged. Gnostic
owns:

- Ascendant and Timeline identity, Turn admission, and replay;
- permission correlation;
- lifecycle supervision.

The agent owns model and tool execution.

### 2. The Timeline record is Gnostic-owned

Gnostic stores a **Timeline record**: the prompts it sent and the normalized
updates it received, for every Timeline, independent of the agent that
operates it. The record holds:

- message chunks;
- tool calls and their status;
- plans;
- usage;
- session projections;
- lineage.

An agent session is a disposable **projection** of a Timeline. To continue a
Timeline, Gnostic uses, in order:

1. the agent's own `session/resume` or `session/load`;
2. otherwise, a new session **seeded** from the record by a declared strategy.

The record states each seeding boundary and what it lost.

Model context, compaction, and caches remain backend-owned (ADR 0002). The
record is what crossed the boundary, not what the model saw. The store is
PositronicKit-free, opt-in under the state home, and built on the kernel's
append-only log (ADR 0014). Its format is versioned. It is delivered by
[#605](https://github.com/phynics/Gnostic/issues/605) and
[#613](https://github.com/phynics/Gnostic/issues/613).

### 3. Workspaces reach agents as MCP servers through a Gnostic gateway

For each ACP session, Gnostic passes one **Gnostic gateway** in `mcpServers` on
`session/new`, `session/load`, and `session/resume`. The gateway serves:

- the tools of the Workspaces attached to that Timeline, named per Workspace;
- the network tools.

Every call goes through Gnostic's effective-status check, its advertised-tool
check, and its permission mediation.

Transport order:

1. stdio, which every agent supports;
2. HTTP, when the agent advertises it;
3. MCP-over-ACP, once that RFD completes.

Gnostic never offers client `fs/*` or `terminal/*`. An intended attachment on an
`acp-client` Ascendant resolves to `available` or `unavailable`, no longer
`unsupported`. This amends ADR 0011's Workspace consequence.

ADR 0011's rejection of routing tool calls through
`AscendantBackendWorkspaceService` still stands, in its precise sense. That
alternative required every tool call of an ACP agent to run through Gnostic,
which would exclude agents that run their own tools. Under this decision, the
agent keeps running its own native tools, and only Gnostic Workspace tools,
which the agent chooses to call, go through the gateway. Delivered by
[#606](https://github.com/phynics/Gnostic/issues/606).

### 4. Subagents are child Timelines

A **subagent** is a child Timeline. It records its parent Timeline, the
spawning Turn, the operating Ascendant, and a lineage kind:

- `delegation`: Gnostic ran a Turn on another Ascendant through the gateway's
  delegation tool. That Ascendant may use another provider.
- `agentSubagent`: the agent's own subagent session, mapped once the Subagent
  Sessions RFD completes.
- `fork`: mapped once `session/fork` completes.

Until those RFDs complete, an agent's internal subagents appear only as tool
calls in the parent's record. Delivered by
[#608](https://github.com/phynics/Gnostic/issues/608).

### 5. The Ascendant definition describes an ACP agent

An Ascendant definition holds:

- identity;
- the ACP launch: command, arguments, environment, working directory, and
  secrets, or a registry identifier;
- **instructions**;
- session configuration, applied through ACP session config options (this is
  where model and mode are set);
- a permission policy;
- default Workspace attachments.

Instructions travel as the ACP system prompt when the agent advertises it.
Otherwise they use a fallback declared per Ascendant. Gnostic never writes into
a user's Workspace to deliver instructions. The backend-envelope keys that
configure an in-process model become deprecated: `provider`, `endpoint`,
`model`, `utilityModel`, `fastModel`, `apiKey`, and `extensions`. Delivered by
[#607](https://github.com/phynics/Gnostic/issues/607).

### 6. Modules have two layers; inner modules live in the Gnostic harness agent

- An **outer module** runs in the host and applies to every ACP agent. Examples:
  gateway tool surfaces, session seeding and rotation, prompt shaping, and
  measurement.
- An **inner module** needs the model loop. Examples: context projection,
  compaction inside a session, cache-aware prompt shaping, and executable
  context. It runs only inside the **Gnostic harness agent**.

The Gnostic harness agent is an ACP agent executable in this repository, built
on PositronicKit. Gnostic hosts it as an ordinary `acp-client` Ascendant, and
an editor can run it directly. It exposes its inner-module and Regime settings
as ACP session config options.

A **Regime** is the agent identity, plus its session configuration, plus the
selected outer modules. Gnostic compares Regimes across third-party agents and
the harness agent on the same scenarios, Workspaces, and Turn log.

The harness agent stays in this repository while the boundary settles. It moves
out when either reconsideration trigger below fires. Delivered by
[#609](https://github.com/phynics/Gnostic/issues/609),
[#612](https://github.com/phynics/Gnostic/issues/612), and
[#614](https://github.com/phynics/Gnostic/issues/614).

Under this rule:

- Ouroboros, Akasha, the semantic context compiler, and Atlas are inner
  experiments. Each is collapsed into a design reference until the harness
  agent exists: [#616](https://github.com/phynics/Gnostic/issues/616),
  [#617](https://github.com/phynics/Gnostic/issues/617),
  [#618](https://github.com/phynics/Gnostic/issues/618), and
  [#619](https://github.com/phynics/Gnostic/issues/619).
- ADR 0016's placement verdicts hold inside the harness agent. Ouroboros keeps
  the detached direct-turn path. Its ACP objections (agent-owned tools and
  system prompt) concern third-party agents, so they do not apply to the
  harness agent.
- Akasha's dispatcher moves from the host into the harness agent, because the
  host no longer invokes models. **Part of ADR 0016's background-activation
  invariant is reopened by this move.** ADR 0016 required a host-owned
  dispatcher whose activations are recorded in the host's durable event log
  (ADR 0014) and mapped to host Turns. Inside the harness agent, the dispatcher
  can own cancellation, budget, and a durable log of its own. But ACP has no
  way to report an activation that happens outside a prompt Turn to the host.
  Until that is resolved, Akasha meets this record's reconsideration trigger
  "an inner experiment needs a host capability ACP cannot carry". The design
  reference #617 must settle it before Akasha restarts.
- RLM is an outer experiment. Its tool is offered through the gateway
  ([#615](https://github.com/phynics/Gnostic/issues/615)).

### 7. PositronicKit firewall

Only harness-agent targets may declare or import any product of the
`PositronicKit` package (for example `PositronicKit`, `PKContracts`,
`PKPrompt`, `PKTestSupport`, or a `PK*Provider`). No other target, including a
test target, may have such a product in its transitive dependency closure.

This widens ADR 0005, which constrains only `GnosticCore`. The rule is a
target. The fitness test that enforces it lands with
[#604](https://github.com/phynics/Gnostic/issues/604), and until then the
existing ADR 0005 checks remain the only enforcement.

The **initial transitional allow-list** is every target that declares a
PositronicKit product on 2026-10-15:

| Kind | Targets | Removed by |
| --- | --- | --- |
| Libraries | `GnosticPositronicBackend`, `GnosticPositronicAtlas`, `GnosticPositronicContext` | #611 (removed, or moved under the harness agent) |
| Libraries | `GnosticHost`, `GnosticCLI` | #604 (move the composition to one transitional target), then #611 |
| Libraries | `GnosticACPFrontend` (`PKContracts` for `AnyCodable` only) | #604 |
| Tests | `GnosticCoreTests`, `GnosticClientTests`, `GnosticRunnerTests`, `GnosticCLITests`, `GnosticPositronicAtlasTests`, `GnosticPositronicContextTests` | #604 for the host test targets; #611 for the module test targets |

The list only shrinks. Adding an entry, or adding a PositronicKit product to a
listed target that did not have it, needs a reviewed exception in
`exceptions.json`.

## Invariant

- No host target (`GnosticProtocol`, `GnosticCore`, `GnosticClient`,
  `GnosticKit`, `GnosticHost`, `GnosticCLI`, `GnosticACPFrontend`,
  `GnosticACPAscendant`, the RLM targets) or host test target has PositronicKit
  in its dependency closure, apart from the transitional allow-list.
- Gnostic Timeline identity and the Timeline record never depend on an agent
  session. Losing a session loses no Gnostic-owned state.
- Every Workspace tool call from an agent crosses Gnostic's effective-status
  and permission checks.
- Inner modules exist only in harness-agent targets. Outer modules never
  require a specific agent.

## Rejected alternatives

- **Keep PositronicKit as the in-process foundation, with ACP as one backend
  among several.** This keeps the #550 coupling and the release waiting on
  upstream. It also keeps comparing experiments against Gnostic's own
  baseline.
- **Drop PositronicKit entirely.** Inner experiments need a model loop Gnostic
  controls, and PositronicKit already supplies one. Moving it behind ACP keeps
  that loop without coupling the host to it.
- **Split the harness agent into its own repository now.** That loses the
  shared scenario harness, Regime records, and registry checks while the
  boundary is still moving. ACP already provides the process boundary, so a
  later split is cheap.
- **Execute agent tools through client `fs/*` and `terminal/*`.** ACP v2
  removes that surface, and agents increasingly sandbox their own execution.
- **Supply history to new sessions as protocol data.** ACP has no such field. A
  `_meta` extension would work only for the harness agent and would hide a
  lossy step. Seeding is explicit and records its loss.
- **Make the agent's session the Timeline's history.** Then switching agents or
  losing a session loses the Timeline. ADR 0002 already separates Timeline
  identity from backend state; the record extends that separation to what
  crossed the boundary.
- **Carry inner experiments through ACP proxies.** Proxies see only messages,
  not the model's context or tool list. The proxy RFD is also a draft. Proxies
  stay a candidate carrier for some outer modules.

## Dependency impact

None in this record. Later children change dependencies, each with its own
resolution evidence:

- #606 adds an MCP server implementation or an exact-pinned MCP SDK.
- #609 adds the harness-agent executable.
- #610 moves the PositronicKit 7.0 pin onto the harness-agent targets.
- #611 removes `GnosticLettaBackend` and `GnosticPositronicBackend`.

`exceptions.json` is unchanged.

## Consequences

- **The host release line no longer waits for PositronicKit.** #551 decision D1
  (0.5.0 waits for PositronicKit 7.0) and decision D2 (`PKSQLiteStorage` as the
  Gnostic Timeline store) no longer apply to the host. D2 moves to the harness
  agent's own session store
  ([#610](https://github.com/phynics/Gnostic/issues/610), which supersedes #550).
  The owner re-sequences #551.
- **Operators of `acp-client` Ascendants gain Gnostic Workspaces** through the
  gateway.
- **The Timeline record writes conversation content to disk** when the state
  home is configured. This is the same opt-in content-at-rest stance as
  ADR 0015.
- **The module registry gains a layer.**
  - `GNO-MOD-ATLAS`, `GNO-MOD-CONTEXT`, `GNO-MOD-OUROBOROS`, and
    `GNO-MOD-AKASHA` are `parked`, owned by their design references.
  - `GNO-MOD-LETTA` is `parked` and owned by #611, which removes the target
    and then archives the entry with the commit that last holds it.
  - Atlas stays selectable in the host (`runnable: true`) as a transitional
    state. It is an inner module in a host target only until #611 moves it
    under the harness agent or archives it.
- **Experiment telemetry depends on what agents report.** When an agent reports
  no usage, the kit records it as unknown.
- **`CONTEXT.md` changes.** It redefines Ascendant Backend, Timeline, Module,
  and Regime, adds the new terms, and lists the terms that are now deprecated.

## Fitness check

- `make docs-check` validates this record, the index, the glossary, and the
  module registry.
- #604 adds the firewall fitness test to `make verify`. It fails when a target
  outside the allow-list reaches a PositronicKit product directly or
  transitively, or when a file outside the allowed directories imports one.
- #612 adds the `layer` check to the module registry.

## Reconsideration triggers

- ACP standardizes supplying history to a new session. Then revisit seeding.
- The Subagent Sessions, `session/fork`, Client-Provided System Prompt, or
  MCP-over-ACP RFD completes, or is withdrawn.
- ACP v2 ships and the client negotiates it.
- The harness agent's release cadence conflicts with the host's, or people want
  to run the harness agent without Gnostic. Then split it into its own
  repository.
- An inner experiment needs a host capability that ACP cannot carry.

## Links

- [Epic #602 — ACP-first host and the Gnostic harness agent](https://github.com/phynics/Gnostic/issues/602)
- [#603 — this decision](https://github.com/phynics/Gnostic/issues/603)
- [ADR 0011 — External ACP agents as Ascendant backends](0011-external-acp-backends.md)
- [ADR 0013 — Gnostic as an experimentation platform](0013-experimentation-platform.md)
- [ADR 0016 — Ouroboros and Akasha executor placement](0016-ouroboros-akasha-executor-placement.md)
- [ACP RFDs](https://agentclientprotocol.com/rfds/about)
- [Epic #140](https://github.com/phynics/Gnostic/issues/140)
- [RESET-001 #145](https://github.com/phynics/Gnostic/issues/145)
