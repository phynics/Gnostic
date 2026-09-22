# ADR 0012 — RLM dual executors with a measured default

## Status

Accepted and amended 2026-09-22 for issue #350.

The single-runtime promotion direction that issue #181 recorded as
`CONTINUE_EXPERIMENT` is superseded for the executor direction. The original
outcome is kept below as history. The #181 benchmark stays valid as historical
baseline evidence, but it is not promotion evidence, and the promotion gate it
was written against is superseded by issue #354's gate.

## Amended decision (2026-09-22)

Guile and Chibi are both offered as selectable RLM executors (`worker` =
`guile` | `chibi`) behind one shared executor seam in `GnosticRLM` (#350). The
repository does not promote one runtime and delete the other.

The default executor, and whether to keep both, is chosen from measured impact
on real Gnostic questions. Issue #354 owns that default-selection evidence
gate: the same scenario manifest, a fixed provider/model family, representative
Gnostic questions with scoring, generated-cell repair rate, token and monetary
cost, latency, and containment incidents. Issue #180's speculative subordinate
calls wait on that decision rather than on a runtime promotion.

The Swift in-process S-expression engine is deferred to issue #355. It is not
rejected; it is revisited after the shared executor seam (#350) and the default
selection (#354) exist.

## Bounded retrieval removed from the required comparison set

The superseded record named bounded retrieval as one of the comparison arms the
next runtime decision required. That arm was never implemented, and no open
issue schedules it. A gate that requires evidence from an unbuilt arm can never
return anything except `CONTINUE_EXPERIMENT`, so the gate as written is
unsatisfiable.

Bounded retrieval is therefore removed from the required comparison set for the
issue #354 evidence gate. This is a decision, not an oversight: the original
record required the arm, the arm was never built, and requiring it would block
the gate permanently. The removal is scoped to this gate and is not permanent.
If bounded retrieval is ever implemented, it re-enters the comparison with the
same scenario manifest and model family as the other arms.

An independent reviewer who disagrees can challenge this removal on the record
here; it is stated so the gate does not quietly require evidence that cannot
exist.

## Superseded decision (issue #181, kept as history)

The decision below is the record accepted for issue #181. It is retained so the
original `CONTINUE_EXPERIMENT` outcome stays readable. It is superseded for the
executor direction by the amended decision above.

Record `CONTINUE_EXPERIMENT` as the runtime-selection outcome for the bounded
RLM experiment. Keep Guile as the semantic reference worker and Chibi as the
Linux production-shaped candidate, but promote neither runtime and do not
start speculative subordinate calls from issue #180.

The repository now contains a reproducible benchmark command:

```text
make benchmark
```

It runs the same bounded corpus/question fixture through the scripted RLM
engine, Guile, and Chibi. It records worker startup, fixture evaluation,
cancellation latency, sampled child RSS and CPU, host-operation counts, model
prompt counts, and semantic result digests. The raw JSON artifact is
`Documentation/Experiments/rlm-runtime-benchmark.json`; the method and one
captured Linux run are described in
`Documentation/Experiments/rlm-runtime-benchmark.md`.

The captured operational result shows that both workers complete the fixture
and produce the same semantic digest. It does not establish a product runtime
choice because ordinary Positronic analysis, bounded retrieval, live answer
quality, monetary cost, generated-cell repair rates, malicious-program safety,
heap/loop containment stress data, and macOS Chibi packaging are not available
in the deterministic repository gate. Worker conformance and malicious-program
coverage remain owned by issues #178 and #179; this benchmark records those
evidence gaps explicitly rather than treating its short fixture as proof.

## Evidence boundary

The benchmark uses deterministic in-memory corpus data and fixed model
responses. It measures runtime mechanics and common-profile parity. It does
not claim provider quality, token billing, or user-task answer quality. Worker
RSS is sampled at startup and after fixture evaluation, and CPU is sampled
from the child process accounting at those points; these are comparative
smoke measurements, not a profiler or a capacity guarantee.

The default-selection decision requires the same scenario manifest, a fixed
provider/model family, representative Gnostic questions with human or
approved evaluator scoring, monetary telemetry, and reproducible macOS
packaging evidence. Repair-rate measurements and stress evidence for heap and
loop containment are also required. Until those inputs exist, the default
executor remains unselected and issue #180 waits on issue #354.

## Rejected alternatives

These rejections were recorded against the superseded single-promotion outcome.
They remain the reason a single up-front promotion is not the current gate.

- `PROMOTE_CHIBI`: rejected because operational parity alone does not measure
  answer quality, cost, or macOS packaging.
- `PROMOTE_GUILE`: rejected because its larger runtime and packaging cost have
  no demonstrated quality advantage in the available evidence.
- `REPLACE_WITH_SWIFT_SEXPRESSION_ENGINE`: deferred to issue #355 because the
  experiment has not yet measured whether general Scheme contributes less value
  than the implementation cost.
- `ARCHIVE`: rejected because both workers complete the common fixture and
  still provide useful evidence for the pending live comparison.

## Consequences

- The repository no longer requires a single up-front runtime promotion. Guile
  and Chibi are both first-class selectable executors behind one seam.
- Issue #180 waits on the default-executor decision in issue #354, not on a
  runtime promotion.
- The Swift in-process engine (issue #355) is deferred, not rejected.
- Bounded retrieval is no longer a required comparison arm for the #354 gate,
  because no implementation exists or is scheduled.
- This amendment changes no source, wire, manifest, or protocol contract.

## Reconsideration triggers

Reconsider the dual-executor decision if issue #354 selects one executor and
retires the other, if one executor cannot meet the shared seam's contract, or if
the deferred Swift engine (issue #355) removes the need for a process-backed
Scheme runtime.
