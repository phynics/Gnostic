# ADR 0002 — Gnostic identity versus backend state

## Status

Accepted target architecture. Delivery is tracked by [Epic #140](https://github.com/phynics/Gnostic/issues/140)
and [RESET-001 #145](https://github.com/phynics/Gnostic/issues/145); this ADR
does not claim that the target implementation is complete.

## Context

A Gnostic Node coordinates Ascendants, Timelines, and Workspaces, while a
backend manages model execution and its own context. Treating a backend
transcript or PositronicKit object as the Gnostic identity would make backend
replacement, failure isolation, and multi-backend hosting ambiguous.

## Decision

Node, Ascendant, Timeline, Workspace, attachment intent, and effective status
are Gnostic-owned identity or relationship concepts. Timeline identity is not
transcript, model context, execution, persistence, compaction, cache, or
checkpoint state. An Ascendant binds to one backend at startup, but its Gnostic
UUID may survive a backend change made while stopped. A backend may project a
Timeline into private state; that projection cannot redefine or erase Gnostic
identity or attachment intent.

PositronicKit `AgentInstance` and `Thread` remain private to the Positronic
Backend. A Workspace is a capability resource and is not inherently a
filesystem. Effective status is `available`, `unavailable`, or `unsupported`,
separate from the durable attachment intent.

Runtime lifecycle fencing is also Gnostic-owned. Shutdown advances the runtime
generation and invalidates backend leases before retiring backend-owned
resources. Backend cancellation and shutdown are best-effort within a bounded
host policy; a noncooperative backend cannot indefinitely hold Gnostic process
shutdown hostage, and any late completion is rejected by the generation and
lease checks.

## Rejected alternatives

- Making a backend transcript the Timeline would couple Gnostic relationships
  to provider-specific persistence and compaction.
- Treating a PositronicKit `Thread` as a public Timeline would leak backend
  implementation identity.
- Replacing attachment intent with current health would silently lose the
  user's relationship when a resource is temporarily unavailable.
- Defining every Workspace as a filesystem would reject non-filesystem
  capability resources.

## Consequences

Gnostic can preserve routing and relationships while backend health changes.
Backends may choose their own transcript and checkpoint representation. The
identity projection, lifecycle rules, and attachment state must be tested at
the Gnostic boundary; lifecycle tests must also prove that late backend
completion cannot restore a fenced identity or lease.

## Reconsideration triggers

Reconsider if a Gnostic-owned operation demonstrably requires provider-owned
transcript identity, if backend replacement cannot preserve the stated
relationship invariants, or if a new resource class cannot be represented as a
capability without filesystem assumptions.

## Links

- [Epic #140](https://github.com/phynics/Gnostic/issues/140)
- [RESET-001 #145](https://github.com/phynics/Gnostic/issues/145)
