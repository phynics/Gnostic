# RLM runtime benchmark

Issue #181 adds a repository benchmark for the bounded RLM runtime decision.
Run it in the pinned development container:

```sh
make benchmark
```

The command builds `gnostic-rlm-benchmark`, runs one versioned fixture, and
writes raw JSON to
[`rlm-runtime-benchmark.json`](rlm-runtime-benchmark.json). The fixture uses
four small in-memory text files, one fixed question, and fixed leaf responses.
The scripted engine, Guile worker, and Chibi worker all inspect the same
conceptual lease and generation-fence material.

For a deterministic replay, set `GNOSTIC_BENCHMARK_TIMESTAMP` and
`GNOSTIC_BENCHMARK_COMMIT` before running the executable. `make benchmark`
sets the commit override from `git rev-parse HEAD`; the timestamp defaults to
the current UTC time unless explicitly provided. The committed artifact is
checked by `GnosticRLMBenchmarkTests` for its schema, outcome, and Guile/Chibi
semantic digest parity.

The worker fixture measures startup, evaluation, cancellation, host-call and
leaf-prompt counts, sampled peak RSS, sampled child CPU time, and a semantic
result digest. The child process is sampled at worker-ready and after fixture
evaluation. CPU is read from `/proc/<pid>/stat`; RSS is the `VmHWM` value from
`/proc/<pid>/status`. A missing process metric is reported as `null`.

The scripted engine is the deterministic orchestration baseline. It has no
child process, so process-resource fields are intentionally `null`. The
ordinary Positronic and bounded-retrieval comparisons remain explicit
unavailable measurements because the repository gate has no provider
credentials, fixed live model family, or bounded-retrieval implementation.
The artifact also records that this fixture does not measure generated-cell
repair rates, malicious-program safety, or heap/loop containment; those
concerns are owned by the worker issues and are not inferred from this smoke
run.

## Captured run

The committed artifact was captured on Linux x86_64 by the benchmark harness at
commit `cd3bd13988bb08584decbafe6e4a8c23f6ac3d12`, recorded in the artifact's
`gitCommit` field. The documentation and decision record were added in the
following commit; rerunning `make benchmark` refreshes both the measurements
and this provenance field.

| Runtime | Startup ms | Evaluation ms | Cancel ms | Sampled peak RSS | Sampled CPU ms | Semantic result |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| scripted engine | 0 | 4.26 | — | — | — | completed |
| Guile | 149.43 | 6.39 | 145.98 | 11.8 MiB | 0 | matching worker digest |
| Chibi | 114.97 | 3.44 | 503.98 | 7.3 MiB | 10 | matching worker digest |

These values are one smoke run, not a confidence interval. The benchmark
records mechanics and semantic parity; it does not infer that Chibi is the
product choice from lower startup or RSS. The recorded outcome is
`CONTINUE_EXPERIMENT` because answer quality, monetary cost, and macOS Chibi
packaging remain unmeasured. See
[ADR 0012](../Architecture/ADRs/0012-rlm-runtime-selection.md) for the
promotion gate and the reason issue #180 remains blocked.
