# ADR 0001 — Axoloty-native multi-backend host

## Status

Accepted target architecture. Delivery is tracked by [Epic #140](https://github.com/phynics/Gnostic/issues/140)
and [RESET-001 #145](https://github.com/phynics/Gnostic/issues/145); this ADR
does not claim that the target implementation is complete.

## Context

Gnostic currently bridges PositronicKit orchestration with Axoloty networking.
The 0.3 reset needs a host boundary that can operate more than one Ascendant
Backend while keeping Gnostic-owned identity, routing, lifecycle, and resource
relationships coherent.

## Decision

Gnostic remains directly Axoloty-native and is an Ascendant host, not a
transport-neutral agent operating system. A narrow mandatory `AscendantBackend`
contract owns execution for one Ascendant and exposes only the host services
needed by demonstrated Gnostic operations. Optional capabilities are separate
from the mandatory contract. Interoperability capabilities are advertised per
Ascendant instance and selected by `protocolMajor` and capability vocabulary;
backend kind and version are diagnostic metadata, not routing assumptions.

The Positronic Backend is one implementation of this boundary. PositronicKit
types and generic Axoloty host plumbing do not escape that backend boundary.

## Rejected alternatives

- A generic transport abstraction would obscure the Axoloty contract Gnostic
  exists to host.
- A Positronic-only Gnostic API would prevent a second backend without making
  the Gnostic boundary explicit.
- Passing raw `CommunicationManager`, `NetworkCatalog`, or other generic host
  objects into backend contracts would couple execution to transport details.

## Consequences

Gnostic-owned host services and backend-owned execution remain independently
testable. A future backend can satisfy the narrow contract without adopting
PositronicKit terminology. The target contract and its implementation are
follow-on work; this ADR establishes the boundary before that code changes.

## Reconsideration triggers

Reconsider this decision if Axoloty is no longer the supported Gnostic network
contract, if a demonstrated host use cannot be expressed through a narrow
service, or if two independent backend implementations require a stable
capability that the boundary cannot represent without transport leakage.

## Links

- [Epic #140](https://github.com/phynics/Gnostic/issues/140)
- [RESET-001 #145](https://github.com/phynics/Gnostic/issues/145)
