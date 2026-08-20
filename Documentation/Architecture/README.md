# Architecture index

This index is the stable entry point for accepted Gnostic architecture
decisions. Canonical domain terms live in [`CONTEXT.md`](../../CONTEXT.md).
Implementation work is tracked in [Epic #140](https://github.com/phynics/Gnostic/issues/140)
and [RESET-001 #145](https://github.com/phynics/Gnostic/issues/145); an ADR
describes an accepted target decision without claiming that undelivered code
already exists.

## Accepted decisions

1. [ADR 0001 — Axoloty-native multi-backend host](ADRs/0001-axoloty-native-multi-backend-host.md)
2. [ADR 0002 — Gnostic identity versus backend state](ADRs/0002-gnostic-identity-vs-backend-state.md)
3. [ADR 0003 — Pre-1.0 manifest and protocol reset](ADRs/0003-pre-1-0-manifest-and-protocol-reset.md)
4. [ADR 0004 — Atlas supersedes Narrative](ADRs/0004-atlas-supersedes-narrative.md)

## Architecture exceptions

[`exceptions.json`](exceptions.json) is the versioned machine-readable
exception registry. RESET-004 records one bounded legacy adapter bridge. Every
exception must have a unique
`id`, the violated `rule`, an exact `scope`, a `rationale`, an owning `issue`,
an `owner`, and `reconsiderWhen` guidance. Scope names concrete files,
packages, targets, or interfaces; wildcard target-wide exceptions are not
allowed.

Exceptions are temporary evidence, not a second architecture. A closed issue
cannot own an active exception, and an exception cannot be silently broadened.
Each entry requires independent review and must be removed or renewed when its
reconsideration condition is reached. RESET-006 owns removal or reduction of
the RESET-004 bridge to a test-only fixture.

Generated-reference validation is not listed here because this repository has
no generated documentation source or generator. The owning issue records that
rationale rather than inventing a generator.
