# ADR 0004 — Atlas supersedes Narrative

## Status

Accepted target architecture. Delivery is tracked by [Epic #140](https://github.com/phynics/Gnostic/issues/140)
and [RESET-001 #145](https://github.com/phynics/Gnostic/issues/145); this ADR
does not claim that Atlas has been implemented or that Narrative has already
been removed.

## Context

Continuity and context behavior currently carries Narrative terminology inside
the Core boundary. The reset needs a deliberately scoped architecture that can
use Positronic-specific context behavior without making it a Gnostic identity
or transport dependency.

## Decision

Atlas is the sole active continuity and context architecture for the target
reset and supersedes Narrative. Atlas is optional, explicitly
Positronic-specific, and incubates outside `GnosticCore` in an optional
`GnosticPositronicAtlas` boundary. Core may contain only generic hooks admitted
by the Core rule: a concept must be required for the Gnostic Axoloty protocol,
multi-backend hosting, or a Gnostic-owned identity, routing, lifecycle, or
resource invariant.

## Rejected alternatives

- Keeping Narrative as a second active continuity architecture would create
  competing ownership and migration paths.
- Making Atlas a Core dependency would couple every backend to Positronic
  context semantics.
- Treating Atlas as generic before a demonstrated cross-backend requirement
  would widen the public contract without evidence.

## Consequences

Future Atlas work can iterate without changing GnosticCore's identity and
transport contracts. Narrative code and tests require classification and
removal work in a later reset increment; this ADR records the accepted target,
not delivery of that increment.

## Reconsideration triggers

Reconsider if a second backend demonstrates the same continuity invariant with
an implementation-independent contract, if keeping Atlas outside Core blocks a
required Gnostic-owned operation, or if the proposed Atlas boundary cannot
preserve backend ownership of context and persistence.

## Links

- [Epic #140](https://github.com/phynics/Gnostic/issues/140)
- [RESET-001 #145](https://github.com/phynics/Gnostic/issues/145)
