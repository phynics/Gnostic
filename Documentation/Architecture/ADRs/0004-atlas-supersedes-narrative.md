# ADR 0004 — Atlas supersedes Narrative

## Status

Accepted and delivered as the RESET-006 boundary. Delivery is tracked by
[Epic #140](https://github.com/phynics/Gnostic/issues/140), [RESET-006 #144](https://github.com/phynics/Gnostic/issues/144),
and [RESET-001 #145](https://github.com/phynics/Gnostic/issues/145). The 0.3
package contains the optional Atlas model and in-memory store foundation;
durable persistence and host integration remain future work.

Epic [#113](https://github.com/phynics/Gnostic/issues/113) delivered the
opt-in end-to-end slice (#115–#119). Its lifecycle review was recorded in
[#382](https://github.com/phynics/Gnostic/issues/382) on 2026-09-24: Atlas
**continues incubation**. It stays an optional library with no executable
consumer. Continued work is owned by
[GNO-ATLAS-001 #115](https://github.com/phynics/Gnostic/issues/115). Types that
only tests construct today, such as the integration coordinator, the fixture and
no-op integrators, and the null observers, are incubation seams, not dead code.

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
transport contracts. Narrative production code and its obsolete tests have
been removed from Core and the runner fixture; any continuity implementation
belongs behind the optional Atlas boundary.

## Reconsideration triggers

Reconsider if a second backend demonstrates the same continuity invariant with
an implementation-independent contract, if keeping Atlas outside Core blocks a
required Gnostic-owned operation, or if the proposed Atlas boundary cannot
preserve backend ownership of context and persistence.

## Links

- [Epic #140](https://github.com/phynics/Gnostic/issues/140)
- [RESET-006 #144](https://github.com/phynics/Gnostic/issues/144)
- [RESET-001 #145](https://github.com/phynics/Gnostic/issues/145)
