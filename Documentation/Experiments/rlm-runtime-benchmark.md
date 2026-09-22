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

## Captured run

The committed artifact was captured on Linux x86_64 at main commit
`62a5ce953539a97288c1b2c9676c1a18e385079b`.

| Runtime | Startup ms | Evaluation ms | Cancel ms | Sampled peak RSS | Sampled CPU ms | Semantic result |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| scripted engine | 0 | 9.24 | — | — | — | completed |
| Guile | 299.17 | 24.40 | 237.96 | 11.7 MiB | 0 | matching worker digest |
| Chibi | 186.67 | 6.40 | 505.87 | 7.3 MiB | 0 | matching worker digest |

These values are one smoke run, not a confidence interval. The benchmark
records mechanics and semantic parity; it does not infer that Chibi is the
product choice from lower startup or RSS. The recorded outcome is
`CONTINUE_EXPERIMENT` because answer quality, monetary cost, and macOS Chibi
packaging remain unmeasured. See
[ADR 0012](../Architecture/ADRs/0012-rlm-runtime-selection.md) for the
promotion gate and the reason issue #180 remains blocked.
