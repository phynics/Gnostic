# RLM scenario questions — #354

Status: **Draft for approval.** These are the 12 questions required by §1 of the
[RLM scenario manifest](rlm-scenario-manifest.md). The manifest fixes the count
and the corpus scope; this file fixes the question text and the reference
answers. Once approved, the question text is frozen before any measurement, and
the reference answers are hashed into the run artifact.

Corpus scope (from manifest §1): `Sources/GnosticCore/Runtime`,
`Sources/GnosticRLM`, and `Documentation/Architecture`. Every question is
answerable from those paths alone. Evidence paths below are the primary places a
correct answer should resolve to; they are not the only acceptable references.

Each entry states the question verbatim, the reference answer, and the elements a
correct answer must contain. The elements are what a reviewer scores against;
they are deliberately structural, so a different wording that carries the same
elements scores the same.

---

## Q1 — Host boundary and the PositronicKit edge

**Question.** What is Gnostic's host boundary, and which PositronicKit values may
cross it?

**Evidence.** `Documentation/Architecture/ADRs/0001-axoloty-native-multi-backend-host.md` (Decision);
`Documentation/Architecture/ADRs/0005-core-positronic-dependency-boundary.md`
(Decision, Import inventory, Public boundary invariant).

**Reference answer.** Gnostic is a directly Axoloty-native Ascendant host, not a
transport-neutral agent operating system. A narrow mandatory `AscendantBackend`
contract owns execution for one Ascendant and exposes only the host services
demonstrated Gnostic operations need; optional capabilities are separate, and
interoperability is advertised per Ascendant instance and selected by
`protocolMajor` and capability vocabulary, never by backend kind. PositronicKit
native types stay inside the bundled backend, the explicit adapters, and the
host bridges listed in ADR 0005; the Core-owned Workspace network contract uses
`ManifestJSONValue`, and conversion lives in `WorkspaceReferenceProjection` and
the adapter seams.

**Required elements.** (a) Ascendant host, not transport-neutral; (b) one narrow
mandatory backend contract, optional capabilities separate; (c) capability
selection by `protocolMajor`/vocabulary, not backend kind; (d) native
PositronicKit values confined to the ADR 0005 adapters/bridges; (e) Gnostic
Workspace network contract uses a Gnostic/Foundation value, not `AnyCodable` or
native Workspace types.

## Q2 — Timeline identity versus backend state

**Question.** How does Gnostic keep Timeline identity independent of backend
transcript state?

**Evidence.** `Documentation/Architecture/ADRs/0002-gnostic-identity-vs-backend-state.md`;
`Documentation/Architecture/ADRs/0008-runtime-created-timeline-durability.md`
(Rejected alternatives).

**Reference answer.** Timeline identity is Gnostic-owned. A backend may project a
Timeline into private transcript/context state, but it cannot redefine or erase
the Gnostic identity; PositronicKit `TimelineRecord` and `AgentInstance` are
backend-private implementation details. Loss or replacement of a backend, or a
backend change made while the Node is stopped, must not lose the Timeline
identity.

**Required elements.** (a) identity is Gnostic-owned; (b) backend may project but
not redefine/erase; (c) PositronicKit timeline/agent values are backend-private;
(d) identity can survive a backend change.

## Q3 — Runtime effect scope as an ownership boundary

**Question.** What is `RuntimeEffectScope`, and what authorities is it
explicitly not?

**Evidence.**
`Sources/GnosticCore/Runtime/RuntimeEffectScope.swift`;
`Documentation/Architecture/ADRs/0006-runtime-effect-ownership-and-terminal-observation.md`.

**Reference answer.** `RuntimeEffectScope` is a structural ownership and cleanup
boundary: adopted effects are released when the scope ends, and one live parent
per child is enforced. It is explicitly not a dependency-injection container, a
service locator, a configuration store, a dynamic loader, or a domain authority.
Fitness tests pin its forbidden dependencies and its named owners, and a
diagnostic-label test keeps dynamic or unsafe content out of scope labels.

**Required elements.** (a) ownership/cleanup boundary; (b) not a DI container,
service locator, config store, dynamic loader, or domain authority; (c) one live
parent per child; (d) forbidden-dependency and label-safety fitness checks.

## Q4 — Terminal Turn observation

**Question.** How does terminal Turn observation deliver an outcome, and what
bounds a stuck observer?

**Evidence.**
`Sources/GnosticCore/Runtime/TerminalTurnObservation.swift`;
`Documentation/Architecture/ADRs/0006-runtime-effect-ownership-and-terminal-observation.md`.

**Reference answer.** It is a one-way, backend-neutral Core seam. Hosts install
`TerminalTurnObserving` values through `NodeRuntimeAdapters`. A
`TerminalTurnRecord` carries only Gnostic identity and a bounded
`TerminalTurnOutcome`; Atlas, Shard, prompt, revision, and PositronicKit types
stay outside the contract. Exact shutdown waits for Turn and lane settlement
before closing the observation fence, then drains admitted observer deliveries
up to `observationDrainTimeout`; only work outliving that window is cut off. A
given observer receives at most one delivery per original identified terminal
Turn, and only if it was admitted before the fence.

**Required elements.** (a) one-way backend-neutral seam installed via
`NodeRuntimeAdapters`; (b) record carries Gnostic identity plus bounded outcome
only; (c) fence closes after settlement; (d) drain bounded by
`observationDrainTimeout`; (e) at most one delivery per terminal Turn.

## Q5 — Runtime-created Timeline durability

**Question.** Does a Timeline created at runtime have to survive a `gnostic
serve` restart, and what exactly is promised across restarts?

**Evidence.** `Documentation/Architecture/ADRs/0008-runtime-created-timeline-durability.md`.

**Reference answer.** No. In the current contract a runtime-created Timeline is
process-scoped and does not have to survive a serve restart. What is promised is
`session/resume` across an ACP-child restart against a live serve, not across a
serve restart. Full durability would need both a node-scoped Gnostic Timeline
identity store (separate from the manifest, which is never written back) and a
durable backend `TimelineRuntimeRepository`. Until then, an orphaned session must
fail `session/resume` with `timelineUnavailable` and be omitted from
`session/list` rather than being recreated implicitly.

**Required elements.** (a) process-scoped, not durable across serve restart; (b)
resume promised only across ACP-child restart against a live serve; (c) needs a
Gnostic identity store plus a durable backend repository; (d) manifest is never
written back; (e) orphaned sessions report `timelineUnavailable` and are omitted
from listing.

## Q6 — Multi-configuration hosting layers

**Question.** What three layers let one Node host distinct Ascendant
configurations, and what must not leak between them?

**Evidence.** `Documentation/Architecture/ADRs/0009-multi-configuration-ascendant-hosting.md`.

**Reference answer.** The three layers are: (1) static composition at the
composition root, which registers every backend kind and compiled-in Positronic
extension and is shared by `serve` and `config`; (2) per-Ascendant selection
through backend settings (`backend.kind` selects the factory; the backend-owned
`settings`/`secrets` configure it; an `extensions` array selects contributions);
and (3) the `PositronicContribution` seam, the only supported extension point for
one Positronic Ascendant, bounded to additional tools plus at most one Turn
context source. Routing is by Ascendant and Timeline identity, never by backend
kind; selecting with no Ascendant ID on a multi-Ascendant Node fails with
`ambiguousAscendant`. A lifecycle-unusable backend failure quarantines only its
own Ascendant, and `GnosticCore` must not depend on the Atlas, RLM, or Letta
targets.

**Required elements.** (a) static composition; (b) per-Ascendant settings with
`backend.kind` and `extensions`; (c) the bounded contribution seam; (d) routing
by identity not kind; (e) `ambiguousAscendant` on unaddressed selection; (f)
failure quarantined per Ascendant; (g) Core free of experiment targets.

## Q7 — RLM budget ownership

**Question.** Who owns an RLM run's limits, and how may a caller change them?

**Evidence.** `Sources/GnosticRLM/RLMRunBudget.swift`.

**Reference answer.** The host owns `RLMRunBudget`, which fixes the wall
duration, root iterations, leaf model calls, estimated model tokens, corpus
file/byte limits, context-read bytes, Scheme cell bytes, Scheme output bytes,
evidence references, chunks per read, search limit, and the recoverable-repair
count (`maxCellRepairs`, default 3). A caller may only *narrow* these values with
an `RLMRunBudgetRequest`: `narrowed(by:)` takes the smaller of the host and
requested value per field, an absent field keeps the host value, and
`resolve(host:request:)` validates first. Negative values throw
`invalidToolArguments`. No tool argument, root cell, or model response can
enlarge a limit.

**Required elements.** (a) host-owned budget; (b) callers may only narrow; (c)
narrowing takes the minimum per field, `nil` keeps host; (d) negative values are
rejected; (e) nothing generated at run time can enlarge a limit.

## Q8 — Recoverable cell failures and repair

**Question.** Which RLM failures can be fed back to the root model for repair,
and how is repairing bounded?

**Evidence.** `Sources/GnosticRLM/RLMFailure.swift`;
`Sources/GnosticRLM/RLMRootLoop.swift` (`rejectScheduledCell`).

**Reference answer.** Only recoverable cell failures can be fed back:
`cellRejected` (validation rejected the cell before evaluation) and
`cellRuntimeFailed` (the cell evaluated but raised a recoverable Scheme error),
as reported by `isRecoverableCellFailure`. Every other failure is terminal, so
fencing, cancellation, worker and protocol faults, and budget exhaustion keep
their prior behavior. The root iteration containing the failed cell is already
consumed, so the repair continuation advances the same root-iteration budget, and
the number of repairs in one run is bounded by `maxCellRepairs`. A repair record
carries a single-line reason bounded to 512 characters.

**Required elements.** (a) only `cellRejected` and `cellRuntimeFailed`; (b) all
others terminal; (c) repair consumes a root iteration; (d) repairs bounded by
`maxCellRepairs`; (e) repair reason is bounded and single-line.

## Q9 — Evidence validation

**Question.** What must an evidence reference satisfy to be accepted, and what
happens when one is rejected?

**Evidence.** `Sources/GnosticRLM/RLMFailure.swift` (`RLMEvidenceRejection`);
`Sources/GnosticRLM/RLMRootLoop.swift` (`finish`); `Sources/GnosticRLM/RLMEvidence.swift`.

**Reference answer.** On `finish`, references are validated against the committed
snapshot: the reference count must not exceed the budget; every chunk ID must be
known; the referenced path must match the chunk's snapshot path; the line range
must not be inverted and must be within the chunk's bounds. A rejection maps to
`evidenceRejected(...)` with the specific reason and terminates the run rather
than completing with unverified evidence; the number of accepted references is
recorded in run metrics.

**Required elements.** (a) validated against the committed snapshot; (b) count
limit; (c) known chunk; (d) path match; (e) non-inverted, in-bounds range; (f)
rejection terminates the run with a structured reason.

## Q10 — Corpus snapshot seam

**Question.** What access does the RLM harness have to corpus bytes, and what
does the snapshot step guarantee?

**Evidence.** `Sources/GnosticRLM/RLMCorpusSource.swift`;
`Sources/GnosticRLM/RLMCorpusSnapshotter.swift`;
`Sources/GnosticRLM/RLMCorpusTypes.swift`.

**Reference answer.** The harness never receives a Workspace path it can open
directly; it sees only the read-only `RLMCorpusSource` seam (`listFiles`,
`readFile`). The snapshotter captures an immutable `RLMCorpusSnapshot` before
evaluation, enforcing the configured file-count and byte limits (`tooManyFiles`,
`corpusTooLarge`) and recording any skipped files, so a run's evidence is
validated against a stable corpus rather than live filesystem state.

**Required elements.** (a) only the `RLMCorpusSource` seam, no openable path; (b)
immutable snapshot taken before evaluation; (c) file-count and byte limits
enforced; (d) skipped files recorded; (e) evidence validated against the
snapshot.

## Q11 — Executor seam and runtime differences

**Question.** What does the shared RLM executor seam own, and where do Guile and
Chibi differences live?

**Evidence.** `Sources/GnosticRLM/RLMWorkerExecutor.swift`;
`Sources/GnosticRLM/RLMWorkerEvaluator.swift`;
`Documentation/Architecture/ADRs/0012-rlm-runtime-selection.md`.

**Reference answer.** `RLMWorkerExecutor` states only what differs between
runtimes: a display name, whether the reviewed build supports the current
platform, and how a configuration becomes an `RLMWorkerLaunchSpec`. Process
supervision, the framed protocol, parent-side cell validation, host servicing,
and the cancellation and wall-time fences are shared. Each executor supplies its
own launch, including host-owned process limits, so the shared worker session
names no executor and branches on no executor-specific behavior. ADR 0012 offers
both runtimes as first-class selectable executors and defers the default choice
to measured impact.

**Required elements.** (a) executor states display name, platform support, launch
spec; (b) supervision/protocol/validation/fences are shared; (c) differences
live in the launch spec; (d) the shared session names no executor; (e) ADR 0012
makes both selectable and measures the default.

## Q12 — Backend failure containment and bounded retirement

**Question.** How is a backend failure contained, and how is backend retirement
bounded?

**Evidence.**
`Sources/GnosticCore/Runtime/BackendRetirementSupervisor.swift`;
`Sources/GnosticCore/Runtime/RuntimeLifecycleCoordinator.swift`;
`Documentation/Architecture/ADRs/0009-multi-configuration-ascendant-hosting.md`
(invariants).

**Reference answer.** An ordinary Turn failure leaves the backend healthy and
usable; only a lifecycle-unusable failure quarantines the Ascendant whose backend
failed, leaving the other Ascendants on the Node serving. Retirement is bounded
by a deadline through the retirement supervisor and lifecycle coordinator: a
retirement or rollback stage that exceeds its deadline is recorded as an exceeded
deadline rather than blocking the Node, and the affected Ascendant is isolated
instead of stalling the others.

**Required elements.** (a) ordinary Turn failure leaves backend healthy; (b) only
lifecycle-unusable failure quarantines, per Ascendant; (c) other Ascendants keep
serving; (d) retirement bounded by a deadline; (e) an exceeded deadline is
recorded, not allowed to block unrelated work.

---

## How these are used

- **Stage 0 (deterministic, no spend).** A scripted deterministic root model
  produces one fixed cell per question over an in-memory corpus built from the
  question's evidence paths. M1–M6, M11 and M12 are recorded per question and per
  executor.
- **Stage 2/3 (live, gated).** The same question text and reference answers are
  used; the reference answer is scored blind to the producing executor, and the
  answer hash is recorded per §7 of the manifest.
- **Freeze.** After approval, the question text is frozen. Any later change is a
  manifest revision with a version bump and a recorded reason, never a silent
  edit.
