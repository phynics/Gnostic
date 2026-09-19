# ADR 0009 — Multi-configuration Ascendant hosting on one Node

## Status

Accepted and delivered by
[#245](https://github.com/phynics/Gnostic/issues/245) under epic
[#241](https://github.com/phynics/Gnostic/issues/241). It depends on the
composition seam from [#242](https://github.com/phynics/Gnostic/issues/242), the
generic contribution seam from
[#243](https://github.com/phynics/Gnostic/issues/243), and per-Ascendant
extension selection from [#244](https://github.com/phynics/Gnostic/issues/244).
Delivery is checked by
[Epic #140](https://github.com/phynics/Gnostic/issues/140) and
[RESET-001 #145](https://github.com/phynics/Gnostic/issues/145) documentation
and architecture gates.

This record reconciles the [#241](https://github.com/phynics/Gnostic/issues/241)
success criteria that concern mixed configuration: distinct Ascendant
configurations coexist on one Node, per-Ascendant selection is explicit,
contributions are private to their selector, backend failure is contained, and
Core stays free of experiment targets. Criteria still owned by other child
issues remain tracked there.

## Context

A Node publishes one `protocolMajor` and may operate several Ascendants
(`CONTEXT.md`). Each Ascendant binds at startup to one Ascendant Backend, and
[ADR 0002](0002-gnostic-identity-vs-backend-state.md) keeps Gnostic identity
independent of backend state. The reset needs Ascendants with different
configurations to run side by side on the same Node: a plain Positronic
Ascendant, a Positronic Ascendant with additional compiled-in behavior, and an
Ascendant served by a different backend kind.

The pieces existed separately before this decision. `AscendantAdapterRegistry`
registered backend kinds ([#242](https://github.com/phynics/Gnostic/issues/242)),
`PositronicContribution` exposed a bounded extension seam
([#243](https://github.com/phynics/Gnostic/issues/243)), and a per-Ascendant
`extensions` setting selected contributions
([#244](https://github.com/phynics/Gnostic/issues/244)). No decision or test
proved that those seams compose on one Node without one configuration leaking
into another, and no fitness check guarded `GnosticCore` against an experiment
target. `Atlas` in particular is an optional Positronic-specific boundary that
must stay outside Core ([ADR 0004](0004-atlas-supersedes-narrative.md)).

## Decision

One Node hosts distinct Ascendant configurations through exactly three layers.
There is no fourth layer.

1. **Static composition.** The composition root registers every backend kind and
   every compiled-in Positronic extension at build time. `gnostic serve` and
   `gnostic config` build the same registry from `BackendComposition`, so a kind
   known to configuration is known to a running Node with the same settings
   schema. Listing kinds and schemas constructs no backend, model, or
   credential-backed client. `NodeRuntime` routes by Gnostic identity and never
   branches on `backend.kind`.
2. **Per-Ascendant selection through backend settings.** The manifest
   `backend.kind` selects the backend factory. The backend-owned `settings` and
   `secrets` envelope configures that Ascendant. The Positronic backend reads an
   optional `extensions` array to select its contributions, and extension
   settings are name-spaced `<extension>.<key>`. An Ascendant without the key is
   the plain configuration and behaves as it did before #244.
3. **The contribution seam.** `PositronicContribution` is the only supported
   extension point for one Positronic Ascendant. A contribution exposes
   additional tools and at most one bounded Turn context source. The surface is
   resolved once at construction and collision-checked against the Workspace and
   network tools, so a contribution cannot override another tool or leak into a
   second Ascendant.

The following invariants hold across the layers:

- Configuration is per Ascendant. Two Ascendants on one Node may select
  different extension sets, and a third may use a different backend kind.
- Failure is contained. An ordinary Turn failure leaves a backend healthy and
  usable; a lifecycle-unusable failure quarantines only the Ascendant whose
  backend failed and leaves the others serving.
- Routing is by Ascendant and Timeline identity, never by backend kind. Remote
  selection by Ascendant ID reaches the addressed Ascendant. Selection with no
  ID on a Node operating more than one Ascendant fails with
  `ambiguousAscendant`.
- `GnosticCore` must not depend on an experiment target. `Atlas`, `RLM`, and
  `Letta` are optional or experimental boundaries outside Core. Core may host
  their adapters through the flat `AscendantBackend` contract, but the Core
  target and Core sources must not import or depend on those targets. Atlas
  stays in `GnosticPositronicAtlas` as [ADR 0004](0004-atlas-supersedes-narrative.md)
  requires; RLM and Letta are not Core dependencies.

## Rejected alternatives

- **One Node-wide configuration with one active backend.** It defeats
  multi-Ascendant hosting and contradicts the Node and Ascendant definitions in
  `CONTEXT.md`.
- **A distinct backend kind per Ascendant variant.** It would turn a
  configuration into a kind, multiply factory registration for every extension
  combination, and make `config` advertise kinds that are really settings.
- **A wider extension seam: pipeline stages or prompt-tree replacement.** The
  contribution seam is deliberately bounded to tools plus one Turn context
  source. A wider surface would let one Ascendant's extension redefine another
  Ascendant's execution and would be unstable to evolve.
- **Hosting Atlas, RLM, or Letta inside Core.** It would couple every backend
  and every build to an experiment. [ADR 0004](0004-atlas-supersedes-narrative.md)
  already rejected this for Atlas.
- **Per-process provider pinning as the routing mechanism.** It was removed by
  [#247](https://github.com/phynics/Gnostic/issues/247); Ascendant identity is
  the route, not a process-local provider selection.

## Consequences

- The bundled Positronic adapter supports arbitrary compiled-in contributions
  without a new backend kind. #244 delivered the `extensions` selection.
- `config` lists and validates extension keys for any registered kind through
  the same advertised settings schema.
- Experiment targets remain optional libraries. A second non-Positronic kind is
  added at the composition root with a settings schema and no Core change.
- This decision changes no wire, manifest-shape, protocol-major, or
  persisted-identity contract. `extensions` is an optional backend-owned
  setting, and an absent key matches the pre-#244 behavior.

## Reconsideration triggers

Reconsider when a required host capability cannot be expressed without a Core
dependency on an experiment target, when a configuration must change while the
Node runs (this decision assumes static composition read at startup), or when a
second backend kind demonstrates the same contribution requirement with an
implementation-independent contract.

## Fitness

This record is checked by `make docs-check`, `make verify`, and
`git diff --check`. `make verify` runs the broker-backed mixed-configuration
suite that proves one Node hosts a plain Positronic Ascendant, a Positronic
Ascendant with a fixture contribution, and a non-Positronic fixture kind; that
contributions reach only their selector; that a quarantined backend does not
affect the other Ascendants; and that remote selection by Ascendant ID reaches
the addressed Ascendant while selection without an ID fails with
`ambiguousAscendant`. A dedicated architecture test fails when the `GnosticCore`
target or any Core source depends on an experiment target. The decision adds no
production dependency.

## Links

- [#245 — prove mixed Ascendant configurations on one Node](https://github.com/phynics/Gnostic/issues/245)
- [#244 — per-Ascendant extension selection](https://github.com/phynics/Gnostic/issues/244)
- [#243 — Positronic contribution seam](https://github.com/phynics/Gnostic/issues/243)
- [#242 — unify backend composition](https://github.com/phynics/Gnostic/issues/242)
- [#241 — multi-configuration epic](https://github.com/phynics/Gnostic/issues/241)
- [ADR 0001 — Axoloty-native multi-backend host](0001-axoloty-native-multi-backend-host.md)
- [ADR 0002 — Gnostic identity versus backend state](0002-gnostic-identity-vs-backend-state.md)
- [ADR 0004 — Atlas supersedes Narrative](0004-atlas-supersedes-narrative.md)
- [ADR 0005 — Core PositronicKit dependency boundary](0005-core-positronic-dependency-boundary.md)
- [Epic #140](https://github.com/phynics/Gnostic/issues/140)
- [RESET-001 #145](https://github.com/phynics/Gnostic/issues/145)
