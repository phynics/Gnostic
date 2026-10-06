# ADR 0013 — Gnostic as an experimentation platform

## Status

Proposed target architecture. Owning issue:
[GNO-PLAT-001 #440](https://github.com/phynics/Gnostic/issues/440). Delivery is
tracked by the umbrella
[Epic #438](https://github.com/phynics/Gnostic/issues/438) and its child epics
P0–P8. Each child epic states whether its part of this decision is delivered.

This record names the target layering and the rules that keep it. It does not
move code. Current deviations are listed under
[Transitional state](#transitional-state), each with the epic that owns its
removal.

## Context

Gnostic is a deconstructed agent harness: one Node hosts several Ascendants,
each bound to an Ascendant Backend (ADR 0001, ADR 0009). The repository has
grown experiments along that seam — Atlas (ADR 0004), bounded RLM analysis
(ADR 0012), external ACP backends (ADR 0011), a Letta prototype (ADR 0010),
and the semantic context experiment
([#426](https://github.com/phynics/Gnostic/issues/426)) — but it has no
explicit statement of what kind of system it is. Three consequences follow.

1. **Experiments cannot always run.** Atlas was decided as *continue
   incubation* in [#382](https://github.com/phynics/Gnostic/issues/382), yet no
   executable target links `GnosticPositronicAtlas`, and
   `NodeRuntimeAdapters.terminalTurnObservers` is populated only by tests.
2. **Experiments rebuild the harness.** RLM carries its own metering, rating,
   and spend guard under `Sources/GnosticCLI/Experiment/`, and the context
   experiment planned its own fixture provider and recording client.
3. **Composition and kernel responsibilities are mixed.** `GnosticCore` holds
   the Node runtime, the bundled Positronic Backend, and the consumer client
   SDK. `GnosticCLI` holds the only full composition root, while
   `GnosticRunner` composes from Core defaults and cannot host ACP, Letta, or
   Positronic extensions.

## Decision

Gnostic is an **experimentation platform**: a small, backend-neutral kernel
that hosts several operating regimes side by side, with experiments packaged as
registered modules that share one platform kit and one composition root.

### Layers

```text
 Apps           gnostic CLI · ACP front end · runner · inspect
 Composition    GnosticHost — the single composition root
 Modules        registered experiments and capabilities (Atlas, Context, RLM, …)
 Platform kit   module registry, Turn interception points, scripted and
                recording models, metering, traces and replay, scenarios,
                scoring, run records
 Backends       Positronic, ACP, Letta — conforming to one backend contract
 Kernel         GnosticCore — identity, manifest, Node runtime, Turn
                coordination, terminal observation, effect scopes,
                Workspace host
 Wire / client  protocol types and the consumer client SDK
```

### Dependency rule

A layer depends only on layers below it.

- The kernel never depends on a backend implementation, the platform kit, a
  module, `GnosticHost`, or an app.
- A module depends on the kernel and the platform kit. It reaches a specific
  backend only through a hook that backend declares, such as
  `PositronicContribution`. Backend-specific modules are allowed and say so in
  their registry entry.
- Every app composes through `GnosticHost`. No app keeps a private registry of
  backends or modules.
- The consumer client SDK does not require a backend implementation to link.

### Modules and their lifecycle

A **Module** is compiled in and selected statically per Ascendant. ADR 0006's
rejection of dynamic plugin loading and mutable post-start registries applies
unchanged.

Every module has an entry in a machine-readable registry,
`Documentation/Architecture/experiments.json`
([GNO-PLAT-002 #441](https://github.com/phynics/Gnostic/issues/441)), with an
open owning issue, a status, and a review date. Statuses:

| Status | Meaning |
| --- | --- |
| `incubating` | Under active experiment; may change without compatibility promise. |
| `gated` | Waiting on a recorded evidence gate. |
| `promoted` | Supported module with a compatibility promise. |
| `parked` | Kept building and testing; no active owner work; has a review date. |
| `archived` | Removed; the entry records the tag or commit that still holds it. |

A gate records exactly one outcome — `PROCEED`, `SIMPLIFY`,
`CONTINUE_EXPERIMENT`, or `ARCHIVE` — in its owning issue, as ADR 0007 and
ADR 0012 already do. A module marked runnable can be enabled from a Node
manifest without code changes.

### Vocabulary

This decision adds **Regime**, **Module**, and **Run** to
[`CONTEXT.md`](../../../CONTEXT.md). A Regime stays a vocabulary term and a
run-record field; named regime profiles in the Node manifest are deferred until
a Run must compare several regimes.

## Rejected alternatives

- **Dynamic plugin loading.** It would add loading and configuration authority
  to the runtime, which ADR 0006 already rejects, and would make the
  composition of a Run impossible to reproduce from the source tree.
- **Split repositories now.** Package and repository boundaries are expensive
  to move. Layer boundaries are proven inside one package first; the package
  split is P7, and extraction into another repository is possible, not
  promised.
- **Regime profiles in the manifest now.** No current experiment compares
  regimes within one Run. Adding manifest structure before a consumer exists
  would fix a schema without evidence.
- **Keep experiments as ad hoc targets.** This is the status quo that produced
  an unrunnable Atlas and duplicated RLM tooling.

## Transitional state

| Deviation | Owner |
| --- | --- |
| The bundled Positronic Backend lives in `GnosticCore`, and its contribution hook is a Core type. | P7 [#460](https://github.com/phynics/Gnostic/issues/460); reopens ADR 0005 with platform neutrality as the benefit. |
| The consumer client SDK lives in `GnosticCore`, which links PositronicKit. | P7 [#460](https://github.com/phynics/Gnostic/issues/460) |
| The ACP front end lives in `GnosticCLI`. | P7 [#460](https://github.com/phynics/Gnostic/issues/460); delivered as the `GnosticACPFrontend` library target. |

These are tracked deviations from a target, not architecture exceptions; they
do not enter `exceptions.json`. A new deviation that is not on this list is an
exception and follows the exception policy.

## Consequences

- New experiments start as modules with a registry entry and an owning issue.
- Composition changes land in `GnosticHost`, so a capability registered once
  is available to every app.
- Backends are compared by one conformance suite
  ([GNO-PLAT-060 #452](https://github.com/phynics/Gnostic/issues/452)) rather
  than by convention.
- Requests for new PositronicKit APIs for experiments are routed through the
  Turn interception epic, P5
  ([#459](https://github.com/phynics/Gnostic/issues/459)).
- Trace recording stays opt-in by construction: the platform kit records no
  payload unless a caller composes a recorder with a tracing transport or tool
  executor. Replay runs offline, serves recorded model responses, and reports
  every divergence instead of passing silently.

## Fitness checks

Existing checks remain: `BackendArchitectureFitnessTests` and the ADR 0005
import inventory. This decision adds, as each layer lands:

- P1: `GnosticCore` does not depend on `GnosticHost`; `GnosticHost` does not
  depend on `GnosticCLI`; every executable composes through `GnosticHost`.
- P0/P2: `make docs-check` validates `experiments.json` against
  `Package.swift` targets and rejects closed owning issues on active entries;
  compiled-in module descriptors match registry entries.
- P7: `GnosticCore` does not depend on PositronicKit, a backend target, the
  platform kit, or any module; the client SDK target does not link a backend.
- P4: the committed replay fixture reproduces from the current harness inside
  `make test`; a mutated tape reports a divergence; no recording code runs on
  a default Run path.
