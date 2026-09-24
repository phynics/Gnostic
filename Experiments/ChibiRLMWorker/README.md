# Chibi RLM worker (experiment)

`worker.scm` is the Chibi Scheme 0.12 worker for the `gnostic-rlm-scheme-0`
profile. It is an experiment and is not enabled in any production composition.

The script ships with the Chibi executor as a bundled resource at
[`Sources/GnosticRLMChibi/Resources/worker.scm`](../../Sources/GnosticRLMChibi/Resources/worker.scm).
The parent resolves it from the bundle, so a deployed binary does not depend on
its working directory; `GNOSTIC_CHIBI_WORKER` overrides the location during
development.

The worker reads length-prefixed frames on stdin, evaluates parent-validated
cells in one run-local restricted environment, and services bounded host calls
over the same framed channel. The parent owns cell validation, host calls,
process supervision, credentials, and every limit; the worker receives no
credential and needs no network access. Process death is the authoritative
termination boundary.

The parent-side client is the shared
[`RLMProcessWorkerSession.swift`](../../Sources/GnosticRLMProcessWorker/RLMProcessWorkerSession.swift),
which supervises every executor. What is specific to Chibi, the shared
`gnostic-rlm-limit-exec` launcher, `CHIBI_MAX_ALLOC` and the Linux-only
platform gate, lives in
[`RLMChibiExecutor.swift`](../../Sources/GnosticRLMChibi/RLMChibiExecutor.swift).
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

The Linux dev-image build applies the reviewed hardening set and cell-timeout
patch, then builds a static binary and installs the one runtime file it needs:

1. Patch `include/chibi/features.h`.
2. Apply [`chibi-cell-timeout.patch`](../../.devcontainer/patches/chibi-cell-timeout.patch) to Chibi's
   `main.c` and `vm.c`.
3. Build the `chibi-scheme-static` target with the `SEXP_USE_DL=0` variable and
   `PREFIX=/usr/local`.
4. Install `chibi-scheme-static` as `/usr/local/bin/chibi-scheme`.
5. Install `lib/init-7.scm` as `/usr/local/share/chibi/init-7.scm`.

The patch is the authoritative flag list; see the `CHIBI_SHA256` step in
[`.devcontainer/Dockerfile`](../../.devcontainer/Dockerfile).

## Shared process limit launcher

Both worker executors require `gnostic-rlm-limit-exec`. The dev image builds and
installs it from the checked-in C source. To install it on a macOS host with
Homebrew's compiler, choose the Homebrew prefix:

```sh
PREFIX="$(brew --prefix)" bash Scripts/install-rlm-limit-exec.sh
```

The launcher verifies each requested resource limit with `getrlimit` before it
replaces itself with the interpreter. Linux applies CPU and address-space
limits. Darwin applies and verifies CPU limits; address-space containment is a
documented gap because Darwin does not provide an equivalent enforceable
`RLIMIT_AS` bound for these workers. The worker's own allocation limits and the
parent's wall deadline remain active.

| Containment property | Linux | macOS |
| --- | --- | --- |
| CPU | Host `RLIMIT_CPU`, verified before exec | Host `RLIMIT_CPU`, verified before exec |
| Address space | Host `RLIMIT_AS`, verified before exec | No `RLIMIT_AS`; Chibi's Scheme heap cap and Guile's per-cell allocation limit remain |
| Wall time | Shared parent deadline terminates the worker | Shared parent deadline terminates the worker |
| File descriptors | Worker tests inspect the Linux child; no separate `RLIMIT_NOFILE` | No dedicated `RLIMIT_NOFILE`; child descriptor inventory is not verified by the macOS gate |
| Environment | Executor supplies a scrubbed environment and the worker reports its launch keys | Executor supplies the same scrubbed environment and launch-key metadata |

The pinned, patched Chibi build is reproduced on macOS by
`bash Scripts/build-chibi-rlm.sh`; it verifies the upstream archive SHA256 and
the reviewed VM guards before compiling. Install Guile 3.0 as a Homebrew system
dependency (`brew install guile`). Gnostic launches that separate executable
and does not bundle or redistribute Guile. Run `make macos-rlm-smoke` to build
both tools and exercise the session, denial, signal, and parity suites.

The macOS build and containment differences are tracked by issue #353.
Benchmark measurements are tracked by issue #354. See
[Scope and deferrals](#scope-and-deferrals).

## Reviewed flags

| Flag | Effect |
| --- | --- |
| `SEXP_USE_DL=0` | Removes dynamic loading. `load` and `include-shared` cannot load shared objects, and the FFI entry points are absent. |
| `SEXP_USE_NO_FEATURES=1` | Disables features that are not explicitly enabled, including UTF-8 strings, type definitions, the simplifier, and full source info. |
| `SEXP_USE_GREEN_THREADS=1` | Re-enabled only for the VM's fuel-based interrupt poll. The worker does not import thread procedures into the cell environment. |
| `SEXP_USE_CHECK_STACK=1` | Enables checked VM stack bounds so a recursive cell can return a recoverable error. |
| `SEXP_USE_GROW_STACK=0` | Keeps the VM stack fixed; recursive cells cannot grow it past the configured size. |
| `SEXP_INIT_STACK_SIZE=8192` | Sets the fixed VM stack capacity in slots; a worker-side guard caps a cell at 512 slots beyond its entry stack depth. |
| `SEXP_USE_MODULES=0` | Removes the module system and the `import` binding. |
| `SEXP_USE_STATIC_LIBS_EMPTY=1` | Builds no statically compiled C libraries, so the process, filesystem, socket, and FFI libraries do not exist. |
| `SEXP_USE_LIMITED_MALLOC=1` | Replaces the allocator with a cap read once from `CHIBI_MAX_ALLOC`. |
| `SEXP_USE_STRICT_TOPLEVEL_BINDINGS=1` | Resolves top-level bindings strictly instead of creating implicit ones. |
| `SEXP_USE_FLONUMS=1` | Re-enabled: the profile admits inexact numbers. |
| `SEXP_USE_BIGNUMS=1` | Re-enabled: the profile admits integers beyond the fixnum range. |
| `SEXP_USE_MATH=1` | Re-enabled: the profile admits `sqrt`, `floor`, `ceiling`, `round`, and `truncate`. |
| `SEXP_USE_RATIOS=0` | Disables exact ratios, so exact division produces a flonum instead of a ratio value. |
| `SEXP_USE_COMPLEX=0` | Disables complex numbers, so `sqrt` of a negative real does not produce a complex value. |
| `SEXP_USE_UTF8_STRINGS` | Left unset. Strings are byte strings, so a character is exactly one byte. Frame I/O depends on this; see [String semantics](#string-semantics-differ-from-guile). |

`SEXP_USE_NO_FEATURES=1` alone does not link in 0.12: `vm.c` references
`sexp_fixnum_to_bignum` when flonums and bignums are both off. Re-enabling
flonums and bignums keeps the reviewed set buildable and satisfies the numeric
part of the profile.

## String semantics differ from Guile

This build leaves `SEXP_USE_UTF8_STRINGS` unset, so strings are byte strings.
A cell that runs string operations over non-ASCII text gets byte counts here
and character counts on the Guile worker:

| Expression | Chibi (this build) | Guile |
| --- | --- | --- |
| `(string-length "café")` | `5` | `4` |

Measured through each worker's decode path, which is the only comparison that
reflects what a cell sees: the Guile worker decodes the frame payload with
`utf8->string`, so `café` arrives as 4 characters, while this worker maps the
5 payload bytes to 5 characters. Note that re-checking with a bare
`guile -c '(string-length "café")'` reports `5`, because Guile reads that
source under the container's C locale rather than as UTF-8; it does not
reproduce the worker path.

**This gap is intrinsic to the reviewed flag set, not an unimplemented
feature.** Enabling UTF-8 strings breaks the worker's frame I/O, which reads
and writes bytes through the character ports: `read-char` rejects a
length-prefix byte >= 128 and `write-char` re-encodes one into a multibyte
sequence, corrupting the 4-byte header.

The obvious repair, porting frame I/O to binary ports as the Guile worker
does, is not available. `SEXP_USE_MODULES=0` and `SEXP_USE_STATIC_LIBS_EMPTY=1`
leave `read-u8`, `write-u8`, `read-bytevector`, `write-bytevector`, the
bytevector ports, `utf8->string` and `string->utf8` out of the image; the
install ships `init-7.scm` alone. Those procedures are module-provided rather
than feature-gated, so enabling `SEXP_USE_UTF8_STRINGS` does not restore them.
Recovering them means re-enabling the module system and the static C libraries,
which are two of the four flags this profile's containment rests on.

Byte-exact framing under UTF-8 would therefore need a new wire format with an
ASCII-safe header, changing the Swift host and the Guile worker as well. That
is not in scope here: the divergence only reaches a generated cell that runs
string operations over non-ASCII corpus text, and `wire-string` already
replaces non-ASCII with `?` on the outbound path.

`worker.scm` asserts the one-byte-per-character invariant at startup and exits
non-zero if a future build enables UTF-8 strings, so the dependency fails
loudly instead of corrupting frames.

## Restricted environment

The default interpreter exposes `eval` and the module system, so command-line
flags alone are insufficient. The worker creates one `(make-environment)` with a
null parent per invocation and imports only the profile's pure operations,
special forms, and host calls with `%import`. Cells are evaluated with
`(eval form run-environment)`. Every other binding, including `eval`, `load`,
`import`, ports, process, environment, network, and FFI procedures, is absent
from the cell environment and fails as an undefined variable even when the
parent validator is bypassed.

The shared profile defines `string-split` with a non-empty string delimiter;
leading, adjacent, and trailing delimiters produce empty fields. Its `sort`
operation is stable for both lists and vectors, and returns the same sequence
type it receives. The [parity corpus](../../Tests/GnosticRLMWorkerParityTests/RLMWorkerWireParityTests.swift)
characterizes these contracts on both workers.

Chibi has no binding for `setrlimit`, and `guard` is not part of this build, so
the worker uses `with-exception-handler` and a captured continuation for
evaluation. The parent launches both executors through the shared limit
launcher described above. Guile's worker does not apply process limits itself.

## Wire rules

Frame payloads are one restricted S-expression written with `write` and
prefixed with a big-endian 32-bit byte length. The `wire-string` rule and the
symbol grammar match the Guile reference worker. The placeholder, unsupported,
and truncated sentinels are characters in both workers, because a cell can forge
any symbol. Improper lists are preserved as dotted pairs, so association-list
values have the same wire shape in both workers.

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
- Every string field the worker emits crosses `wire-string`, including the
  ready-frame `runID` and `environmentKeys` and each result frame's `runID`, so
  this worker stays in wire parity with Guile when a host-supplied identity or
  environment key contains a control character.

## Limits and differences from Guile

- The host sends `SIGUSR1` at the per-cell time limit. The patched VM consumes
  the interrupt at a fuel checkpoint, and the worker reports
  `cell time limit exceeded` while keeping its run-local environment alive.
  Deep non-tail recursion is capped at 512 VM stack slots beyond the cell's
  entry depth and reports `cell recursion limit exceeded`. The parent
  wall deadline remains the authoritative kill backstop for blocked host calls,
  uninterruptible C work, or an interrupt failure.
- `CHIBI_MAX_ALLOC` is set from `maxHeapBytes`. It caps the Scheme heap for the
  worker's lifetime, not per cell and not the process RSS. Large-allocation
  fixtures fail recoverably under this process-wide cap, but unlike Guile's
  32 MiB per-cell allocation limit, the Chibi cap is cumulative across cells.
  This remains a bounded executor difference, not a per-cell accounting claim.
- The worker reads its own environment from `/proc/self/environ`, so the `ready`
  frame reports the real scrubbed key set. It can not enumerate its open file
  descriptors, so `openFileDescriptorCount` is `-1`; a parent-side test reads
  `/proc/<pid>/fd` to prove the child holds only its standard descriptors.

## Scope and deferrals

macOS support and its containment differences are tracked by issue #353, and
live impact measurements belong to issue #354. Until the macOS smoke job passes,
macOS Chibi support remains unverified. #181's captured benchmark is historical
operational evidence, not a runtime-selection result.
