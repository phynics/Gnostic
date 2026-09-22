# Guile RLM worker (experiment)

`worker.scm` is the GNU Guile 3.0 reference worker for the
`gnostic-rlm-scheme-0` profile. It is an experiment and is not enabled in any
production composition.

The script ships with the Guile executor as a bundled resource at
[`Sources/GnosticRLMGuile/Resources/worker.scm`](../../Sources/GnosticRLMGuile/Resources/worker.scm).
The parent resolves it from the bundle, so a deployed binary does not depend on
its working directory; `GNOSTIC_GUILE_WORKER` overrides the location during
development.

The worker reads length-prefixed frames on stdin, evaluates parent-validated
cells in one run-local `(ice-9 sandbox)` module, and services bounded host calls
over the same framed channel. The parent owns cell validation, host calls,
process supervision, credentials, and every limit; the worker receives no
credential and needs no network access. Process death is the authoritative
termination boundary.

The Guile interpreter is a container system dependency. The parent-side client
is the shared session in `Sources/GnosticRLMProcessWorker`, which supervises
every executor; what is specific to Guile, its launch arguments and platform
support, lives in `Sources/GnosticRLMGuile`. The shared frame codec and profile
validator live in `Sources/GnosticRLM`.

## Shared wire values

Guile and Chibi use the same restricted wire-value contract. Strings contain
printable ASCII plus TAB, LF, and CR; other characters become `?`. Symbols use
an ASCII identifier beginning with a letter and continuing with letters,
digits, or `-`; invalid symbols become the character `#\~`. A value that is
unsupported by the parent model becomes `#\!`, and a conversion that exceeds
the bounded value budget becomes `#\?`.

Numbers are accepted only when they are finite real values or signed 64-bit
integers. Ratios, complex values, non-finite values, and integers outside the
signed 64-bit range become `#\!`. This keeps Guile's result frames identical
to Chibi's for the common profile, including the numeric edge cases.

Every string field the worker emits crosses `wire-string`, not only cell
values. The `ready` frame's `runID` and `environmentKeys`, each result frame's
`runID`, `finished` answers and evidence identifiers, failure messages, and
host-call names are all sanitized before framing. A host-supplied identity or
environment key that contains a control character therefore cannot make a
frame undecodable.
