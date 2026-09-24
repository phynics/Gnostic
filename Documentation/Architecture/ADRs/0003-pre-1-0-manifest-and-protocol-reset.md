# ADR 0003 — Pre-1.0 manifest and protocol reset

## Status

Accepted target architecture. Delivery is tracked by [Epic #140](https://github.com/phynics/Gnostic/issues/140)
and [RESET-001 #145](https://github.com/phynics/Gnostic/issues/145); this ADR
does not claim that manifest or protocol changes are delivered.

## Context

The pre-1.0 contracts mix generic Agent/Chat terminology with backend settings
and do not make protocol compatibility explicit. A coordinated reset is safer
than carrying incompatible contracts indefinitely while adding backend kinds.

## Decision

The 0.3 reset introduces a bounded manifest v2 envelope owned by each
Ascendant's backend configuration. Top-level reusable `llmProfiles` are not
part of the target written format. Gnostic validates bounded structure and
redacts the complete `secrets` subtree; each backend validates its own settings.
The v1-to-v2 migration preserves Node, Ascendant, Timeline, Workspace,
relationship, broker, and credential data with atomic-write and owner-only
backup/source guarantees. Configuration mutation remains local CLI behavior.

The reset is a deliberate network break: Gnostic-owned Agent becomes
Ascendant, generic Chat becomes Turn, and required `protocolMajor` accompanies
Gnostic advertisements, requests, results, streams, and replay updates.
Missing or unsupported majors fail structurally; incompatible objects are
hidden from normal discovery and revalidated at inspection and direct-call
boundaries. External ACP and backend-native Agent terminology remains bounded
to those boundaries.

## Rejected alternatives

- Incrementally co-advertising old and new wire families would make compatibility
  and routing ambiguous.
- Letting Gnostic semantically validate every backend setting would turn the
  host into a provider-specific configuration system.
- Keeping top-level profiles would preserve an identity model the reset is
  explicitly removing.
- Silently accepting a missing protocol major would allow incompatible peers to
  appear routable.

## Consequences

Existing 0.2 clients and written manifests require an explicit migration or
reset boundary. The target provides a bounded host contract and deterministic
compatibility checks, at the cost of intentional pre-1.0 breakage. Manifest
and protocol implementation remain separate follow-on increments and are not
asserted by this documentation change.

## Reconsideration triggers

Reconsider if migration cannot preserve the listed identity and relationship
invariants atomically, if a required backend setting cannot be safely bounded
or redacted, or if compatibility evidence shows the selected major boundary
cannot distinguish interoperable peers.

## Amendment — migration retired after 0.4

[#381](https://github.com/phynics/Gnostic/issues/381) retires the migration
paths this ADR introduced. Gnostic 0.3 through 0.4 carried them. After 0.4,
loading a schema v1 manifest fails with `unsupportedSchemaVersion` and a
message that names 0.4 as the last release that migrated it. A pre-manifest
flat configuration file is reported as malformed. Neither file is rewritten. The
`_legacyID` marker written by the pre-#164 CLI is no longer stripped, and the
`.legacy` backup is no longer created.

Invariant: the CLI reads and writes only the current manifest schema, and never
rewrites a file it rejects.

Rejected alternative: keep the migrations indefinitely. They preserved an
identity model (top-level `llmProfiles`) that this ADR removed, and they were
the only remaining readers of it.

The protocol-major-2 wire fallbacks are unaffected. These are the `isAvailable`
Workspace field and the unpaginated `workspace.list` request. Retiring them
requires a new protocol major.

## Links

- [Epic #140](https://github.com/phynics/Gnostic/issues/140)
- [RESET-001 #145](https://github.com/phynics/Gnostic/issues/145)
