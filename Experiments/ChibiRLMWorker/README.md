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
`https://codeload.github.com/ashinn/chibi-scheme/tar.gz/refs/tags/0.12`,
extracted with `tar --extract --gzip --strip-components=1`.

The build applies the reviewed hardening set, then builds a static binary and
installs the one runtime file it needs:

1. Patch `include/chibi/features.h`.
2. Build the `chibi-scheme-static` target with the `SEXP_USE_DL=0` variable and
   `PREFIX=/usr/local`.
3. Install `chibi-scheme-static` as `/usr/local/bin/chibi-scheme`.
4. Install `lib/init-7.scm` as `/usr/local/share/chibi/init-7.scm`.

The patch is the authoritative flag list; see the `CHIBI_URL` step in
[`.devcontainer/Dockerfile`](../../.devcontainer/Dockerfile).

The build is verified against Linux only. macOS is external: there is no
verified macOS Chibi build, and the session reports `unsupportedPlatform`
outside Linux.

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
prefixed with a big-endian 32-bit byte length. The worker applies the same
sanitization as the Guile reference worker:

- `wire-string`: printable ASCII plus LF, TAB, and CR; every other byte becomes
  `?`.
- `wire-symbol`: `^[A-Za-z][A-Za-z0-9-]*$`, otherwise `gnostic-symbol`.
- Unsupported values become `gnostic-unsupported`; the conversion is bounded by
  a 4096-node budget and a depth of 32.

## Limits and differences from Guile

- The parent applies `RLIMIT_CPU` and `RLIMIT_AS` with `prlimit`, enforces the
  wall deadline and the output cap, sends the cancel frame, and kills the
  process. `CHIBI_MAX_ALLOC` is set from `maxHeapBytes`.
- Chibi can not read environment keys or list open file descriptors, so the
  `ready` frame reports an empty key list and `-1` for the descriptor count.
  Credential absence is proved by the scrubbed host environment and by the
  worker rejecting `getenv`, file, and process forms.
- There is no separate per-cell time or allocation facility. A cell that loops
  is bounded by the parent wall deadline, which terminates the worker. A cell
  that exhausts the heap raises `out of memory`, which the worker maps to
  `resource limit exceeded` and survives.
