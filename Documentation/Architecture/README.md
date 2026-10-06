# Architecture index

This index is the stable entry point for accepted Gnostic architecture
decisions. Canonical domain terms live in [`CONTEXT.md`](../../CONTEXT.md).
Implementation work is tracked in [Epic #140](https://github.com/phynics/Gnostic/issues/140),
[RESET-006 #144](https://github.com/phynics/Gnostic/issues/144), and
[RESET-001 #145](https://github.com/phynics/Gnostic/issues/145); each ADR states
whether its decision is delivered or remains a target.

## Accepted decisions

1. [ADR 0001 — Axoloty-native multi-backend host](ADRs/0001-axoloty-native-multi-backend-host.md)
2. [ADR 0002 — Gnostic identity versus backend state](ADRs/0002-gnostic-identity-vs-backend-state.md)
3. [ADR 0003 — Pre-1.0 manifest and protocol reset](ADRs/0003-pre-1-0-manifest-and-protocol-reset.md)
4. [ADR 0004 — Atlas supersedes Narrative](ADRs/0004-atlas-supersedes-narrative.md)
5. [ADR 0005 — Core PositronicKit dependency boundary](ADRs/0005-core-positronic-dependency-boundary.md) — re-evaluated after ACP delivery; Positronic remains bundled pending a measured build or independent ownership/release benefit.
6. [ADR 0012 — RLM dual executors with a measured default](ADRs/0012-rlm-runtime-selection.md)
7. [ADR 0006 — Runtime effect ownership and terminal observation](ADRs/0006-runtime-effect-ownership-and-terminal-observation.md)
8. [ADR 0008 — Runtime-created Timeline durability across serve restarts](ADRs/0008-runtime-created-timeline-durability.md) — process-scoped default; superseded in part by ADR 0015 when a durable state home is configured.
9. [ADR 0009 — Multi-configuration Ascendant hosting on one Node](ADRs/0009-multi-configuration-ascendant-hosting.md)
10. [ADR 0010 — Letta as the first non-Positronic Ascendant backend](ADRs/0010-letta-ascendant-backend-evaluation.md)
11. [ADR 0011 — External ACP agents as Ascendant backends](ADRs/0011-external-acp-backends.md)
12. [ADR 0014 — Durable Turn event log](ADRs/0014-durable-turn-event-log.md)
13. [ADR 0015 — File-backed Timeline runtime repository](ADRs/0015-file-backed-timeline-runtime-repository.md) — durable backend transcripts, opt-in under the state home.

The Timeline-bound backend session document that was published on
`codex/timeline-bound-backend-sessions` also used the number 0006. That branch
document is historical and is not an accepted architecture decision. [ADR 0007
— Timeline-bound backend session contract disposition](ADRs/0007-timeline-bound-backend-session-contract-disposition.md)
records the `ARCHIVE` outcome. The accepted ADR 0006 is the runtime effect and
terminal observation decision listed above.

## Proposed decisions

- [ADR 0013 — Gnostic as an experimentation platform](ADRs/0013-experimentation-platform.md) — target layering, dependency rule, and Module lifecycle. Owning issue [#440](https://github.com/phynics/Gnostic/issues/440); delivery tracked by [Epic #438](https://github.com/phynics/Gnostic/issues/438).

## Historical and disposition records

- [ADR 0007 — Timeline-bound backend session contract disposition](ADRs/0007-timeline-bound-backend-session-contract-disposition.md)

ADR 0010 records the Letta backend as an optional, experimental prototype. The
`GnosticLettaBackend` target stays outside `GnosticCore` and is registered
through the composition source; it is not production support.

The current compatibility declaration is [0.4.2](../Compatibility/0.4.2.md); it is additive over [0.4.1](../Compatibility/0.4.1.md), [0.4.0](../Compatibility/0.4.0.md) and the delivered 0.3 reset baseline [documented here](../Compatibility/0.3.0.md).

## Extension guides

- [Implementing an Ascendant backend](../Extending/ascendant-backends.md)
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
active entry, and rejects a target that is not declared in `Package.swift`. It
also rejects a compiled-in module descriptor whose `registryID` has no matching
entry, so a module and its registry record cannot drift apart. An empty
`targets` array is allowed: it means the module has no compiled target yet. The
issue-state rule runs when `GH_TOKEN` or `GITHUB_TOKEN` reaches the GitHub API;
the checker self-test always pins the closed-owner rejection so it cannot
silently rot.

The same check keeps the registry and the compiled-in module descriptors from
drifting apart in the other direction too: a `runnable` entry must have a
compiled-in `GnosticModule` descriptor whose `registryID` is that entry's `id`,
so a module reaches `runnable` only after its descriptor is compiled in. #449
and #450 own those two wiring steps.

The platform kit boundary is enforced the same way. `GnosticCore` must not
depend on or import `GnosticKit`; the kit must depend on `GnosticCore` and no
other `Gnostic` target; and `Sources/GnosticKit` must not import a Positronic
backend. The kernel therefore stays below the kit, so P7 can extract Positronic
from `GnosticCore` without touching the kit.

`GnosticProtocol` is the backend-neutral wire boundary below `GnosticCore`. It
depends only on Axoloty and `AxolotyWire`, carries no PositronicKit or kernel
dependency, and `GnosticCore` re-exports it for source compatibility. ADR 0005
records the boundary and its fitness checks.

Archived entries may name a closed owning issue: that is the expected terminal
state, and the entry records the review decision rather than active ownership.

## Architecture exceptions

[`exceptions.json`](exceptions.json) is the versioned machine-readable
exception registry. It records one accepted exception, `GNO-EXC-0001`, for the
Coaty vocabulary that `GnosticCore` still publishes through
`Sources/GnosticCore/Compatibility/AxolotyCompatibility.swift` and that
`GnosticProtocol` publishes through
`Sources/GnosticProtocol/CoatyObjectModel.swift`. Every
exception must have a unique
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
