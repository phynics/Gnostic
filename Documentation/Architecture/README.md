# Architecture index

This index is the stable entry point for accepted Gnostic architecture
decisions. Canonical domain terms live in [`CONTEXT.md`](../../CONTEXT.md).
Implementation work is tracked in [Epic #140](https://github.com/phynics/Gnostic/issues/140),
[RESET-006 #144](https://github.com/phynics/Gnostic/issues/144), and
[RESET-001 #145](https://github.com/phynics/Gnostic/issues/145); each ADR states
whether its decision is delivered or remains a target.

## Accepted decisions

1. [ADR 0001 — Axoloty-native multi-backend host](ADRs/0001-axoloty-native-multi-backend-host.md) — amended by ADR 0018: Axoloty is the discovery and routing fabric, not the agent or tool protocol.
2. [ADR 0002 — Gnostic identity versus backend state](ADRs/0002-gnostic-identity-vs-backend-state.md)
3. [ADR 0003 — Pre-1.0 manifest and protocol reset](ADRs/0003-pre-1-0-manifest-and-protocol-reset.md)
4. [ADR 0004 — Atlas supersedes Narrative](ADRs/0004-atlas-supersedes-narrative.md)
5. [ADR 0005 — Core PositronicKit dependency boundary](ADRs/0005-core-positronic-dependency-boundary.md) — the v0.5 host and its test targets have no PositronicKit dependency. Only the standalone reference Runtime executable may depend on it (ADR 0021).
6. [ADR 0012 — RLM dual executors with a measured default](ADRs/0012-rlm-runtime-selection.md)
7. [ADR 0006 — Runtime effect ownership and terminal observation](ADRs/0006-runtime-effect-ownership-and-terminal-observation.md)
8. [ADR 0008 — Runtime-created Timeline durability across serve restarts](ADRs/0008-runtime-created-timeline-durability.md) — process-scoped default; superseded in part by ADR 0015 when a durable state home is configured.
9. [ADR 0009 — Multi-configuration Ascendant hosting on one Node](ADRs/0009-multi-configuration-ascendant-hosting.md)
10. [ADR 0010 — Letta as the first non-Positronic Ascendant backend](ADRs/0010-letta-ascendant-backend-evaluation.md) — superseded by ADR 0017; the prototype is retired by #611.
11. [ADR 0011 — External ACP agents as Ascendant backends](ADRs/0011-external-acp-backends.md) — historical ACP and Workspace gateway decision. The v0.5 contract uses ACP v2 over stdio and has no Gnostic Agent identity (ADR 0021).
12. [ADR 0014 — Durable Turn event log](ADRs/0014-durable-turn-event-log.md)
13. [ADR 0015 — File-backed Timeline runtime repository](ADRs/0015-file-backed-timeline-runtime-repository.md) — historical Positronic transcript store, superseded by the authoritative Timeline journal. ADR 0021 defines the v0.5 journal contract and does not migrate the old transcript files.
14. [ADR 0013 — Gnostic as an experimentation platform](ADRs/0013-experimentation-platform.md) — layering, dependency rule, and Module lifecycle; delivered by [Epic #438](https://github.com/phynics/Gnostic/issues/438) (P0–P8). ADR 0021 makes clear that no research Module is required by the v0.5 host; model-loop experiments use independent ACP Runtimes.
15. [ADR 0016 — Ouroboros and Akasha executor placement](ADRs/0016-ouroboros-akasha-executor-placement.md) — both experiments remain parked design references. ADR 0021 removes any v0.5 host-harness requirement and uses independent ACP Runtime processes for future experiments that need a model loop.
16. [ADR 0017 — ACP-first host and PositronicKit firewall](ADRs/0017-acp-first-host-and-harness-agent.md) — historical decision for the ACP boundary, Timeline record, Workspace gateway, and PositronicKit firewall. ADR 0021 supersedes the Ascendant identity, mandatory subagent lineage, single harness agent, and broad harness-target exception. Only the standalone reference Runtime may depend on PositronicKit.
17. [ADR 0018 — Gnostic primitives after the ACP pivot](ADRs/0018-gnostic-primitives-after-the-acp-pivot.md) — historical direction for Agent identity, spans, ACP payloads, Axoloty routing, and Workspace roots. ADR 0020 removed the Agent primitive. ADR 0021 supersedes the remaining v0.5 contracts for Turn admission, Workspace placement, and Runtime boundaries.
18. [ADR 0019 — ACP v2 as Gnostic's protocol baseline](ADRs/0019-acp-v2-protocol-baseline.md) — strict ACP v2 only, with no v1 path; the 0.5.0 ACP interface is an opt-in preview, and unanswered permissions receive the v2 `cancelled` outcome. ADR 0021 replaces its Runtime queue and quiet-period idle inference with busy rejection before insertion and durable Timeline journaling. Other retained protocol rules are identified in ADR 0021.
19. [ADR 0020 — Timeline-first primitives: no Agent, Session records, Projects, and Runtime kinds](ADRs/0020-timeline-first-primitives.md) — Timeline-first identity, Session records, and Node-scoped Runtime instances. ADR 0021 replaces scratch-only placement and special-Node Native Runtimes with local or scratch Projects and ACP v2 stdio processes. It also makes the Timeline journal durable and fixes one owning Node per Timeline.
20. [ADR 0021 — Gnostic v0.5 architecture reconciliation](ADRs/0021-gnostic-v0-5-architecture-reconciliation.md) — binding v0.5 contract for durable Timeline authority, the ACP v2 stdio Runtime boundary, single-active-Turn admission, local or scratch Projects, gateway Workspaces, and release and migration scope. It supersedes or amends the conflicting sections of ADRs 0017–0020. Delivery is tracked by [#640](https://github.com/phynics/Gnostic/issues/640), [Epic #602](https://github.com/phynics/Gnostic/issues/602), and [Epic #551](https://github.com/phynics/Gnostic/issues/551).

The [Timeline journal format reference](Timeline-Journal-Format.md) documents
the versioned JSON-lines record, replay epochs, and recovery rules in ADR 0021 §5.

The Timeline-bound backend session document that was published on
`codex/timeline-bound-backend-sessions` also used the number 0006. That branch
document is historical and is not an accepted architecture decision. [ADR 0007
— Timeline-bound backend session contract disposition](ADRs/0007-timeline-bound-backend-session-contract-disposition.md)
records the `ARCHIVE` outcome. The accepted ADR 0006 is the runtime effect and
terminal observation decision listed above.

## Historical and disposition records

- [ADR 0007 — Timeline-bound backend session contract disposition](ADRs/0007-timeline-bound-backend-session-contract-disposition.md)

ADR 0010 records the retired Letta backend prototype. Its implementation and
target were removed by #611; Letta can return only as an ACP Runtime.

The compatibility declaration in development is [0.5.0](../Compatibility/0.5.0.md), a source-breaking minor over [0.4.2](../Compatibility/0.4.2.md). The released declarations are [0.4.2](../Compatibility/0.4.2.md), [0.4.1](../Compatibility/0.4.1.md), [0.4.0](../Compatibility/0.4.0.md) and the delivered 0.3 reset baseline [documented here](../Compatibility/0.3.0.md).

## Extension guides

- [ACP Runtime integration](../Extending/ascendant-backends.md)
- [Implementing a Workspace adapter](../Extending/workspace-adapters.md)
- [Building an experiment on the platform kit](../Extending/experiment-kit.md)
- [ACP SDK evaluation](ACP-SDK-Evaluation.md)

## Experiments and modules

[`experiments.json`](experiments.json) is the versioned machine-readable
module registry defined by [ADR 0013](ADRs/0013-experimentation-platform.md).
Every Module has an entry with a unique `id`, a `name`, the `targets` it adds
to `Package.swift`, a lifecycle `status` (`incubating`, `gated`, `promoted`,
`parked`, or `archived`), its `owningIssue` and one or more `gateIssues`,
whether it is `runnable` from a manifest, and a `reviewBy` date.

`make docs-check` validates the schema, rejects a closed owning issue on an
active entry, and rejects a target that is not declared in `Package.swift`. The
registry is research lifecycle metadata. It does not compile descriptors into
the host or make a research target a dependency of a release executable. A
`runnable` entry names its isolated package targets; an empty `targets` array
means the design has no implementation target yet. The `verify` workflow
passes `GITHUB_TOKEN` to `make verify`, so the issue-state rule runs on every
pull request and every push to `main`; the checker self-test pins the closed-
owner rejection.

The platform kit boundary is enforced the same way. `GnosticCore`,
`GnosticHost`, and `GnosticCLI` have no direct or transitive experiment-target
dependency. `GnosticKit` depends on `GnosticCore` only and imports no Runtime
implementation. The separate `GnosticExperimentCLI` owns the Kit and RLM
dependencies; `gnostic experiment` forwards to it without linking it into the
host executable.

`GnosticACPWire` contains the Gnostic-owned ACP v2 wire types and depends only
on Foundation. The standalone reference Runtime uses this target without
linking Axoloty. `GnosticACPAscendant` adapts a supervised stdio ACP process to
the host's Runtime coordination. `GnosticHost`, `GnosticRunner`, and
`GnosticCLI` compose this adapter. PositronicKit appears only in the standalone
`GnosticPositronicRuntime` executable; no host or test target depends on it.

`GnosticClient` is the consumer SDK above the kernel. It exposes typed Turn,
Timeline, Workspace, and Diagnostics clients. Their public signatures use
`GnosticProtocol` types only; `GnosticCore` is an implementation dependency,
not part of the client API (D13, #675). The host owns Timeline authority, admission, supervision, and
Workspace authorization. ACP owns Runtime session behavior. ADR 0021 defines
these roles and their fitness checks.

`Tests/GnosticCoreTests/PositronicKitFirewallTests.swift` enforces the
dependency rule. It parses `Package.swift` and Swift sources, permits PK only
in the standalone Runtime executable, checks host dependency closure, and
detects seeded illegal declarations, imports, and transitive paths. The
transitional allowance GNO-EXC-0002 was removed with #611.

Archived entries may name a closed owning issue: that is the expected terminal
state, and the entry records the review decision rather than active ownership.

## Architecture exceptions

[`exceptions.json`](exceptions.json) is the versioned machine-readable
exception registry. It records two exceptions. `GNO-EXC-0001` covers the
Coaty vocabulary that `GnosticCore` still publishes through
`Sources/GnosticCore/Compatibility/AxolotyCompatibility.swift` and that
`GnosticProtocol` publishes through
`Sources/GnosticProtocol/CoatyObjectModel.swift`. `GNO-EXC-0003` covers the
backend sending `session/prompt` without an observed `idle`, which ADR 0019
section 2 still requires. The owner accepted it in decision D21 on issue #681,
and issue #687 owns it until it is retired. Every exception must have a unique
`id`, the violated `rule`, an exact `scope`, a `rationale`, an owning `issue`,
an `owner`, and `reconsiderWhen` guidance. Scope names concrete files,
packages, targets, or interfaces; wildcard target-wide exceptions are not
allowed.

Exceptions are temporary evidence, not a second architecture. A closed issue
cannot own an active exception, and an exception cannot be silently broadened.
Each entry requires independent review and must be removed or renewed when its
reconsideration condition is reached.

Generated-reference validation is not listed here because this repository has
no generated documentation source or generator. The owning issue records that
rationale rather than inventing a generator.
