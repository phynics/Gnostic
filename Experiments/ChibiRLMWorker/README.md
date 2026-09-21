# Chibi RLM worker (experiment)

`worker.scm` is the Chibi Scheme 0.12 worker for the `gnostic-rlm-scheme-0`
profile. It is an experiment and is not enabled in any production composition.

The worker reads length-prefixed frames on stdin, evaluates parent-validated
cells in one run-local restricted environment, and services bounded host calls
over the same framed channel. The parent owns cell validation, host calls,
process supervision, credentials, and every limit; the worker receives no
credential and needs no network access. Process death is the authoritative
termination boundary.

The parent-side client lives in
[`RLMChibiWorkerSession.swift`](../../Sources/GnosticRLMChibi/RLMChibiWorkerSession.swift).
The shared frame codec and profile validator live in
[`RLMSchemeProfile.swift`](../../Sources/GnosticRLM/RLMSchemeProfile.swift).

## Pinned build

The interpreter is built from the Chibi 0.12 release tag during the dev image
build. The exact source is
`https://codeload.github.com/ashinn/chibi-scheme/tar.gz/refs/tags/0.12`, and the
build verifies its SHA256
`b70a1147bc70a0f90df3fb6081bc99808237fd17a9accf9ee7a2cc20d95a4df0` with
`sha256sum -c` before extraction. Chibi is a pinned system dependency outside
SwiftPM, so the repository SBOM target does not cover it.

The build applies the reviewed hardening set, then builds a static binary and
installs the one runtime file it needs:

1. Patch `include/chibi/features.h`.
2. Build the `chibi-scheme-static` target with the `SEXP_USE_DL=0` variable and
   `PREFIX=/usr/local`.
3. Install `chibi-scheme-static` as `/usr/local/bin/chibi-scheme`.
4. Install `lib/init-7.scm` as `/usr/local/share/chibi/init-7.scm`.

The patch is the authoritative flag list; see the `CHIBI_SHA256` step in
[`.devcontainer/Dockerfile`](../../.devcontainer/Dockerfile).

The build is verified against Linux only. macOS support and benchmark
measurements are deferred to issue #181; there is no verified macOS Chibi build,
and the session reports `unsupportedPlatform` outside Linux. See
[Scope and deferrals](#scope-and-deferrals).

## Reviewed flags

| Flag | Effect |
| --- | --- |
| `SEXP_USE_DL=0` | Removes dynamic loading. `load` and `include-shared` cannot load shared objects, and the FFI entry points are absent. |
| `SEXP_USE_NO_FEATURES=1` | Disables features that are not explicitly enabled: interpreter threads, UTF-8 strings, type definitions, the simplifier, and full source info. |
| `SEXP_USE_MODULES=0` | Removes the module system and the `import` binding. |
| `SEXP_USE_STATIC_LIBS_EMPTY=1` | Builds no statically compiled C libraries, so the process, filesystem, socket, and FFI libraries do not exist. |
| `SEXP_USE_LIMITED_MALLOC=1` | Replaces the allocator with a cap read once from `CHIBI_MAX_ALLOC`. |
| `SEXP_USE_STRICT_TOPLEVEL_BINDINGS=1` | Resolves top-level bindings strictly instead of creating implicit ones. |
| `SEXP_USE_FLONUMS=1` | Re-enabled: the profile admits inexact numbers. |
| `SEXP_USE_BIGNUMS=1` | Re-enabled: the profile admits integers beyond the fixnum range. |
| `SEXP_USE_MATH=1` | Re-enabled: the profile admits `sqrt`, `floor`, `ceiling`, `round`, and `truncate`. |
| `SEXP_USE_RATIOS=0` | Disables exact ratios, so exact division produces a flonum instead of a ratio value. |
| `SEXP_USE_COMPLEX=0` | Disables complex numbers, so `sqrt` of a negative real does not produce a complex value. |

`SEXP_USE_NO_FEATURES=1` alone does not link in 0.12: `vm.c` references
`sexp_fixnum_to_bignum` when flonums and bignums are both off. Re-enabling
flonums and bignums keeps the reviewed set buildable and satisfies the numeric
part of the profile.

## Restricted environment

The default interpreter exposes `eval` and the module system, so command-line
flags alone are insufficient. The worker creates one `(make-environment)` with a
null parent per invocation and imports only the profile's pure operations,
special forms, and host calls with `%import`. Cells are evaluated with
`(eval form run-environment)`. Every other binding, including `eval`, `load`,
`import`, ports, process, environment, network, and FFI procedures, is absent
from the cell environment and fails as an undefined variable even when the
parent validator is bypassed.

Chibi has no binding for `setrlimit`, and `guard` is not part of this build, so
the worker uses `with-exception-handler` and a captured continuation for
evaluation, and the parent applies the CPU and address-space rlimits.

## Wire rules

Frame payloads are one restricted S-expression written with `write` and
prefixed with a big-endian 32-bit byte length. The `wire-string` rule and the
symbol grammar match the Guile reference worker. The placeholder, unsupported,
and truncated sentinels are characters here instead of Guile's symbols, because
a cell can forge any symbol; the two workers therefore agree on the value model
but not on the sentinel type.

- `wire-string`: printable ASCII plus LF, TAB, and CR; every other byte becomes
  `?`.
- A symbol matching `^[A-Za-z][A-Za-z0-9-]*$` passes through. Any other symbol
  becomes the character `#\~`, which no cell value can produce because every
  genuine character becomes `#\!`.
- Numbers outside the parent model become the character `#\!`: a non-finite
  flonum, an integer beyond the signed 64-bit range, or a ratio or complex
  value. The character markers are a distinct type, so a cell that creates a
  symbol literally named `gnostic-symbol`, `gnostic-unsupported`, or
  `gnostic-truncated` is not confused with a sanitized or unsupported value.
- Unsupported non-number values become `#\!`. The conversion is iterative over
  list spines and vector elements, so the 4096-node budget and depth of 32 are
  enforced without growing the C stack; truncation becomes `#\?`.

## Limits and differences from Guile

- The parent applies `RLIMIT_CPU` and `RLIMIT_AS` with `prlimit`, and proves the
  CPU limit by terminating a runaway worker. It enforces the wall deadline and
  the output cap, sends the cancel frame, and kills the process.
- `CHIBI_MAX_ALLOC` is set from `maxHeapBytes`. It caps the Scheme heap
  high-water mark, not the process RSS.
- The worker reads its own environment from `/proc/self/environ`, so the `ready`
  frame reports the real scrubbed key set. It can not enumerate its open file
  descriptors, so `openFileDescriptorCount` is `-1`; a parent-side test reads
  `/proc/<pid>/fd` to prove the child holds only its standard descriptors.
- There is no separate per-cell time or allocation facility. A cell that loops
  is bounded by the parent wall deadline, which terminates the worker. A cell
  that exhausts the heap raises `out of memory`, which the worker maps to
  `resource limit exceeded` and survives.
- Deep non-tail recursion can overflow the inherited C stack and terminate the
  worker, or be cut by the parent wall deadline first, depending on the stack
  limit; either way the parent contains it and the worker is terminated.

## Scope and deferrals

macOS support and benchmark measurements are out of scope for this increment and
are deferred to issue #181. This worker is Linux-only and unmeasured; the
deferral is recorded in PR #340 and accepted here, and the GitHub issue
checklist is updated separately.
