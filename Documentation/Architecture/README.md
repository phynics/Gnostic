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
5. [ADR 0005 — Core PositronicKit dependency boundary](ADRs/0005-core-positronic-dependency-boundary.md)
6. [ADR 0006 — Runtime effect ownership and terminal observation](ADRs/0006-runtime-effect-ownership-and-terminal-observation.md)
7. [ADR 0008 — Runtime-created Timeline durability across serve restarts](ADRs/0008-runtime-created-timeline-durability.md)
8. [ADR 0009 — Multi-configuration Ascendant hosting on one Node](ADRs/0009-multi-configuration-ascendant-hosting.md)
9. [ADR 0010 — Letta as the first non-Positronic Ascendant backend](ADRs/0010-letta-ascendant-backend-evaluation.md)

The Timeline-bound backend session document that was published on
`codex/timeline-bound-backend-sessions` also used the number 0006. That branch
document is historical and is not an accepted architecture decision. [ADR 0007
— Timeline-bound backend session contract disposition](ADRs/0007-timeline-bound-backend-session-contract-disposition.md)
records the `ARCHIVE` outcome. The accepted ADR 0006 is the runtime effect and
terminal observation decision listed above.

## Historical and disposition records

- [ADR 0007 — Timeline-bound backend session contract disposition](ADRs/0007-timeline-bound-backend-session-contract-disposition.md)

ADR 0010 records the Letta backend as an optional, experimental prototype. The
`GnosticLettaBackend` target stays outside `GnosticCore` and is registered
through the composition source; it is not production support.

The current compatibility declaration is [0.4.2](../Compatibility/0.4.2.md); it is additive over [0.4.1](../Compatibility/0.4.1.md), [0.4.0](../Compatibility/0.4.0.md) and the delivered 0.3 reset baseline [documented here](../Compatibility/0.3.0.md).

## Extension guides

- [Implementing an Ascendant backend](../Extending/ascendant-backends.md)
- [Implementing a Workspace adapter](../Extending/workspace-adapters.md)

## Architecture exceptions

[`exceptions.json`](exceptions.json) is the versioned machine-readable
exception registry. It records one accepted exception, `GNO-EXC-0001`, for the
Coaty vocabulary that `GnosticCore` still publishes through
`Sources/GnosticCore/Compatibility/AxolotyCompatibility.swift`. Every
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
