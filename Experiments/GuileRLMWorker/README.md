# Guile RLM worker (experiment)

`worker.scm` is the GNU Guile 3.0 reference worker for the
`gnostic-rlm-scheme-0` profile. It is an experiment and is not enabled in any
production composition.

The worker reads length-prefixed frames on stdin, evaluates parent-validated
cells in one run-local `(ice-9 sandbox)` module, and services bounded host calls
over the same framed channel. The parent owns cell validation, host calls,
process supervision, credentials, and every limit; the worker receives no
credential and needs no network access. Process death is the authoritative
termination boundary.

The Guile interpreter is a container system dependency. The parent-side client
lives in `Sources/GnosticRLMGuile`, and the shared frame codec and profile
validator live in `Sources/GnosticRLM`.
