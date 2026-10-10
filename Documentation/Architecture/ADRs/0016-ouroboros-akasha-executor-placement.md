# ADR 0016 — Ouroboros and Akasha executor placement

## Status

Accepted (2026-10-11). Owning issue:
[GNO-OURO-001 #465](https://github.com/phynics/Gnostic/issues/465), with
[Epic #464](https://github.com/phynics/Gnostic/issues/464) (Ouroboros) and
[Epic #478](https://github.com/phynics/Gnostic/issues/478) (Akasha) as the
experiments this record places.

This record is a placement decision with evidence. The owner accepted it on
2026-10-11 and decided the points listed under
[Owner decisions](#owner-decisions). The evidence is read from source only:
no Turn was run, and the items under [Unverified](#unverified) are
reconsideration triggers, not accepted facts. No production code, backend
target, or registry runnable flag changes with this record, and no
implementation of either experiment has started.

## Context

Ouroboros ([`CONTEXT.md`](../../../CONTEXT.md) Image, Image invocation) is a
Module ([ADR 0013](0013-experimentation-platform.md)) that drives its own loop.
It needs a backend hook that offers four things:

1. a model call where the host supplies the system context and exactly one tool
   (`repl`), with no backend-native tools exposed;
2. no backend-owned transcript or compaction across invocations;
3. provider usage with cached and uncached input tokens;
4. a model choice per Regime.

Akasha ([Epic #478](https://github.com/phynics/Gnostic/issues/478)) adds three
requirements. Its activations begin with a host-made `(recent-messages)` tool
call that the model must see as its own. Its background activations run outside
any Turn, so cancellation, budget, and observation must have an owner
([ADR 0006](0006-runtime-effect-ownership-and-terminal-observation.md)). And its
Turn completes on a correlated message rather than on a run that returns
([#487](https://github.com/phynics/Gnostic/issues/487)).

[ADR 0009](0009-multi-configuration-ascendant-hosting.md) keeps composition
static and forbids Core dependencies on experiment targets. [ADR 0011](0011-external-acp-backends.md)
states that an ACP agent owns its own model and tool execution. The placement
question is whether any declared hook carries these invariants, and only then
whether a dedicated backend kind is needed.

## Spike evidence (read-only)

The spike read the current sources and the PositronicKit revision pinned in
`Package.resolved` (`https://github.com/phynics/PositronicKit.git`, revision
`b3b82fed5a9bf747aa37bc5640b5d78df5a90c74`, tag `6.1.0`). A local checkout at
`3081794` also exists. Its code differs, so this record cites only the pinned
revision for PositronicKit facts.

### Q1 — Positronic Turn interception (verdict: NO for the tool list; PARTIAL for system context)

The interception types live in `Sources/GnosticKit/TurnInterception.swift`.
The wiring lives in `Sources/GnosticHost/BackendComposition.swift:266-271`,
where `InterceptingLLMStreamClient` wraps the model client and
`TurnInterceptionMiddleware.wrap` is passed as `toolMiddleware`.

- **System context: partial.** `TurnInterceptionModelRequest` carries
  `messages: [TurnInterceptionMessage]` and `tier`
  (`TurnInterception.swift:68`, `:70`). It has no system-prompt field. The
  system text reaches the wire as a `.system` message
  (PositronicKit `Sources/PositronicKit/Services/Prompting/RenderedPrompt+Messages.swift:84`),
  so a request hook can rewrite it. The rewrite is outgoing only. It does not
  change the prompt PositronicKit stores.
- **Tool list: NO.** `InterceptingLLMStreamClient.generationStream` passes
  `tools: tools` through unchanged on both paths
  (`Sources/GnosticHost/TurnInterceptionAdapters.swift:54` and `:77`). The
  request type has no tools field. `TurnInterceptionMiddleware.wrap` maps each
  tool to a wrapper (`TurnInterceptionAdapters.swift`, the final `enum`), so the
  count is preserved and tools can be wrapped but not removed. The adapter
  supplies `toolMiddleware(workspaceTools + networkTools + contributionTools)`
  (`Sources/GnosticPositronicBackend/PositronicAscendantAdapter.swift:423`).
  It also enables `installTimelineObservationTools: true` and
  `installsTimelineSendTool: true` (`PositronicAscendantAdapter.swift:157-158`).
  PositronicKit's `TimelineToolRegistry.getEnabledTools` appends workspace and
  provider tools regardless of the Turn's tool list (pinned revision,
  `Services/Timeline/TimelineToolRegistry.swift`). Suppressing the surface to
  one tool therefore also needs the runtime policy and the registry, which
  interception does not reach.
- **Transcript: NO through interception.** PositronicKit loads the stored
  timeline history for every Turn (`Services/Turn/TurnPreparation.swift:305-311`
  at the pinned revision). The hook can drop history from the outgoing messages,
  but it cannot stop the stored history from growing or being reread.
- **Host-made assistant tool calls: partial.** `TurnInterceptionMessage` carries
  `toolCalls` (`TurnInterception.swift`, `TurnInterceptionToolCallRecord`), so a
  request hook can put an assistant tool call on the wire. PositronicKit does not
  record it, so the next request diverges from the stored history. This is the
  ledger problem Akasha must avoid.
- **Round and response hooks:** `TurnRoundIntercepting` is not wired by the
  Positronic adapter. Only model and tool hooks are used.

**Candidate that the interception spike did not cover.** PositronicKit 6.1.0
exposes `TimelineHandle.startDirectTurn(_:context:options:)`
(`Sources/PositronicKit/Timelines/TimelineHandle.swift`, pinned revision). It
takes a `DirectTurnContext` whose `systemInstructions` is the complete system
prompt (`Models/Turn/TurnExecution.swift:31-34`) and a `TurnOptions.tools` list.
A direct Turn is valid only while the timeline has no attached Agent
(`TimelineHandle.swift`, `TurnError.directExecutionRequiresDetachedTimeline`).
`TurnPreparation.swift:282-287` sets `effectiveTools` to the request tools plus
workspace direct tools only, and `:335-337` states that direct Turns do not
inherit an Agent. That is the seam that could satisfy requirements 1 and 2
together, but **the transcript is still loaded** (`:305-311`), so requirement 2
holds only if each Image invocation uses a fresh detached timeline that is
deleted afterwards. This route is unverified by execution and needs the
`makeRequest` path checked for registry tools before any verdict is final.

### Q2 — ACP (verdict: NOT a candidate for either experiment)

- **Native tools and system prompt cannot be suppressed.** ADR 0011 makes the
  agent the owner of model and tool execution. The backend opens sessions with
  `mcpServers: []` (`Sources/GnosticACPAscendant/ACPAscendantBackend.swift:236`,
  `:251`, `:624`), so no `repl` server is attached. The session request carries
  `cwd` and `mcpServers` only. No system-prompt field is set. The community SDK
  (`aptove/swift-sdk` `v0.1.16`, per `ACP-SDK-Evaluation.md`) was not
  inspected in this spike, so its request shape is unverified.
- **Token usage: not reported.** `GnosticACPAscendant` has no usage handling
  (`grep usage` returns nothing). Whether the agent reports usage at all is
  unverified.
- **Transcript and compaction: owned by the agent.** Each ACP session is
  backend-private state (ADR 0011). A fresh `session/new` per invocation can
  start clean, but each agent may keep its own history or caches outside
  Gnostic's control.
- **Host-made assistant tool calls and background activations:** the ACP
  boundary has no hook for a host-authored assistant message, and no activation
  outside a Turn. Akasha is ruled out here.
- **Live evidence is absent.** `ACP-SDK-Evaluation.md` records that no live
  Swift-client handshake or real-agent transcript exists.

**Benchmark confounds if ACP is ever measured.** An external agent brings its own
system prompt, native tools, context compaction, caching, and model choice, and
each of the three target agents (opencode, Codex, Claude Agent) differs in all
of them. Token usage may be missing, which makes the telemetry incomparable with
the Positronic baseline. Any ACP comparison is therefore a comparison of agents,
not of Ouroboros.

### Q3 — Letta (fit note only)

Letta is a parked backend ([`experiments.json`](../experiments.json),
`GNO-MOD-LETTA`). ADR 0011 names Letta's client-side tool model as the one
delegating adapter that fits a Gnostic-routed tool surface. Letta keeps its own
server-side state and transcript by design, so it fails requirement 2 unless the
server's state is disabled. This note is not a full evaluation. The Letta
backend ADR (0010) was not reviewed in depth for this record.

### Q4 — Dedicated backend kind (the fallback; cost against the Module lifecycle)

A dedicated Ascendant Backend kind would be a flat `AscendantBackend`
implementation registered through `BackendComposition`
(ADR 0009, ADR 0011). It would own lifecycle, health, cancellation, shutdown,
terminal observation ([ADR 0006](0006-runtime-effect-ownership-and-terminal-observation.md)),
persistence, and a settings schema. It would also have to pass the single
conformance suite ([#452](https://github.com/phynics/Gnostic/issues/452)).
That is a full backend surface, which the Module lifecycle does not require:
a Module needs a registry entry, one compiled-in descriptor, and an optional
interception or contribution hook
([ADR 0013](0013-experimentation-platform.md)). A dedicated kind is justified
only when no declared hook can carry the invariants, and no hook has yet been
falsified for Ouroboros.

### Q5 — Akasha's extra requirements

- **Host-made assistant tool calls:** partial through interception (see Q1),
  but a stored-history divergence rules out the hook as the carrier.
- **Background activations outside a Turn:** no backend hook exists.
  `AscendantBackend.runTurn` is the only activation point, and a
  `TimelineHandle` admits only Turns (`TimelineHandle.swift`). ADR 0006 observes
  only Turns. Akasha needs a host-owned dispatcher above the backend that owns
  cancellation, budget, and observation, with its own record in the durable
  event log ([ADR 0014](0014-durable-turn-event-log.md)).
- **Turn completion on a correlated message:** `consumeTurnEvents` completes on
  the final stream event, not on a correlated message. A host-owned mapping from
  the user endpoint to the Turn is needed ([#487](https://github.com/phynics/Gnostic/issues/487)).

## Decision

The owner accepted this decision. It separates the two experiments.

1. **Ouroboros** is a **Module** (ADR 0013) named `GNO-MOD-OUROBOROS`. It runs
   its own Image invocation loop. It reaches the Positronic backend only through
   a declared hook. The hook to test first is the detached direct-turn path
   described under Q1. The Turn interception hook is **not** the carrier,
   because the tool list cannot be changed. A dedicated backend kind is **not**
   promoted at this time. ACP is not a candidate.
2. **Akasha** is a **Module** named `GNO-MOD-AKASHA`. Its dispatcher, background
   activations, and correlated Turn mapping live in a host-owned Module layer
   above the backend, not in a backend hook. It needs a model-invocation seam
   that does not require a Turn. The existing `PositronicContributionModelService`
   (`Sources/GnosticPositronicBackend/PositronicContributionRuntimeContext.swift`)
   returns text only and cannot carry tool calls, so it is insufficient on its
   own. ACP is not a candidate. A dedicated backend kind is the fallback only if
   the host-owned layer cannot meet the background-activation invariant.

The two verdicts can differ. This record does not promote any backend.

## Invariant

- The model sees exactly the tools the Module declares for a given invocation.
  A hook that cannot change the tool list is not a carrier for Ouroboros.
- An activation's model context is rebuilt from committed Image source and
  invocation input. It is not carried over from a backend transcript.
- A background activation has one owner for cancellation, budget, and terminal
  observation. Its record is written to the durable event log.
- The model sees host-made tool calls as its own. The stored history and the
  wire history cannot diverge.

## Rejected alternatives

- **Turn interception as the carrier for Ouroboros.** Rejected: the request
  type has no tool field, and the runtime registry adds tools that interception
  cannot remove (Q1).
- **ACP for either experiment.** Rejected: native tools and the system prompt
  cannot be suppressed, usage is unreported, and background activation has no
  hook (Q2, Q5).
- **Dedicated backend kind now.** Deferred as the fallback. It costs a full
  backend surface and a conformance pass, and no Module hook has been falsified
  yet (Q4).
- **Letta for either experiment.** Rejected for requirement 2 by its
  server-side state (Q3).

## Dependency impact

- No production dependency is added by this record.
- Each experiment's Module target depends on `GnosticCore` and the platform kit
  (`GnosticKit`) and reaches the backend only through a declared hook
  (ADR 0013). A backend-specific hook lives in `GnosticPositronicBackend` or
  `GnosticHost`, not in `GnosticCore`.
- The `ExperimentUsage` kit gap is recorded as follow-up
  [#576](https://github.com/phynics/Gnostic/issues/576): it reports prompt and
  completion tokens only and has no cached or uncached split. The interception
  usage type `TurnInterceptionUsage` has the same limit. This record does not
  implement the split.

## Fitness check

`GnosticCore` must not depend on the Ouroboros target, and must not depend on
the Akasha target. The check is named
`OuroborosAkashaArchitectureFitnessTests.coreDoesNotDependOnExperimentTargets`
and is to be added with the first target that lands
([#469](https://github.com/phynics/Gnostic/issues/469) for Ouroboros). The
existing ADR 0009 rule already forbids an experiment-target dependency from
Core, so this check adds a name to the rule rather than a new boundary.

## Owner decisions

Decided by the owner on 2026-10-11.

1. **Placement accepted.** Both experiments are Modules. The names
   `GNO-MOD-OUROBOROS` and `GNO-MOD-AKASHA` are accepted.
2. **First Ouroboros hook to test: the detached direct-turn path.** The Turn
   interception hook is rejected for the tool list. Testing the path is a spike
   and does not commit to building Ouroboros.
3. **Akasha background activations: a host-owned Module dispatcher above the
   backend.** A backend kind is the fallback only if that dispatcher cannot meet
   the background-activation invariant.
4. **PositronicKit 7.0 timing is not decided here.** It is tracked by
   [#550](https://github.com/phynics/Gnostic/issues/550). Re-check this record
   when 7.0 lands, because `TimelineFork` and
   `GenerationTransport.requestResponse` bear on the transcript requirement.
5. **ACP is excluded.** There is no ACP benchmark arm for either experiment.

## Unverified

- Whether PositronicKit's registry-installed runtime tools
  (`installTimelineObservationTools`, `installsTimelineSendTool`) enter the
  model's tool list on the direct-turn path. The spike read the pinned source
  but did not run a Turn.
- Whether a fresh detached timeline per invocation is cheap enough in storage and
  latency. Not measured.
- The ACP community SDK's request shape, its usage reporting, and whether any
  agent accepts a system prompt. Not measured.
- No live model or backend call was made. All verdicts are source-based.

## Reconsideration triggers

- The direct-turn spike falsifies the registry-tool question, or proves that a
  fresh detached timeline per invocation is impractical.
- PositronicKit 7.0 changes the transcript or the request type.
- An ACP agent exposes a session-scoped system prompt and a tool allow-list.
- A host-owned Akasha dispatcher cannot meet the background-activation invariant.

## Links

- [GNO-OURO-001 #465](https://github.com/phynics/Gnostic/issues/465)
- [Epic #464 — Ouroboros](https://github.com/phynics/Gnostic/issues/464)
- [Epic #478 — Akasha](https://github.com/phynics/Gnostic/issues/478)
- [#576 — ExperimentUsage cached and uncached token split](https://github.com/phynics/Gnostic/issues/576)
- [ADR 0005 — Core PositronicKit dependency boundary](0005-core-positronic-dependency-boundary.md)
- [ADR 0006 — Runtime effect ownership and terminal observation](0006-runtime-effect-ownership-and-terminal-observation.md)
- [ADR 0009 — Multi-configuration Ascendant hosting](0009-multi-configuration-ascendant-hosting.md)
- [ADR 0010 — Letta as the first non-Positronic backend](0010-letta-ascendant-backend-evaluation.md)
- [ADR 0011 — External ACP agents as Ascendant backends](0011-external-acp-backends.md)
- [ADR 0013 — Gnostic as an experimentation platform](0013-experimentation-platform.md)
- [ADR 0014 — Durable Turn event log](0014-durable-turn-event-log.md)
