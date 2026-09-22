# ADR 0012 — RLM runtime selection remains an experiment

Status: Accepted for issue #181

## Decision

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

The next promotion decision requires the same scenario manifest, a fixed
provider/model family, representative Gnostic questions with human or
approved evaluator scoring, monetary telemetry, and reproducible macOS
packaging evidence. Repair-rate measurements and stress evidence for heap and
loop containment are also required. Until those inputs exist,
`CONTINUE_EXPERIMENT` is the bounded outcome and issue #180 remains blocked.

## Rejected alternatives

- `PROMOTE_CHIBI`: rejected because operational parity alone does not measure
  answer quality, cost, or macOS packaging.
- `PROMOTE_GUILE`: rejected because its larger runtime and packaging cost have
  no demonstrated quality advantage in the available evidence.
- `REPLACE_WITH_SWIFT_SEXPRESSION_ENGINE`: deferred because the experiment has
  not yet measured whether general Scheme contributes less value than the
  implementation cost.
- `ARCHIVE`: rejected because both workers complete the common fixture and
  still provide useful evidence for the pending live comparison.
