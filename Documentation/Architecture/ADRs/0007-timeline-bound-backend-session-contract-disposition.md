# ADR 0007 — Timeline-bound backend session contract disposition

## Status

Accepted. Outcome: **ARCHIVE**.

The flat `AscendantBackend` contract on `main` remains the accepted target. The
Timeline-bound session contract is historical and is not being re-landed or
redesigned by this decision.

## Context

Issues [#191](https://github.com/phynics/Gnostic/issues/191) through
[#194](https://github.com/phynics/Gnostic/issues/194) delivered a clean,
source-breaking Timeline-bound backend session contract in commits
`abc2b3c`, `8b5fd23`, `c323fde`, and `533e9f7`. Issue
[#199](https://github.com/phynics/Gnostic/issues/199) then restored `main` to
the pre-session baseline in commit `89c792b` and retained the implementation on
`codex/timeline-bound-backend-sessions`.

The separation kept that completed experiment isolated while the runtime
ownership and terminal observation work proceeded on the flat contract. That
reason was not recorded in #199. The later work landed through runtime PRs
[#258](https://github.com/phynics/Gnostic/pull/258) and
[#264](https://github.com/phynics/Gnostic/pull/264), so the dependent seams are
now settled on `main` without the Timeline-session source break.

The current repository ADR 0006 is [Runtime effect ownership and terminal
observation](0006-runtime-effect-ownership-and-terminal-observation.md). The
preservation branch's `0006-timeline-bound-backend-execution.md` is therefore a
number collision, not a second current ADR.

## Evidence

- `origin/main` is `48f8fdb`, the current tip and squash commit for runtime
  hardening PR #264.
- `origin/codex/timeline-bound-backend-sessions` is `533e9f7`.
- `533e9f7` is an ancestor of `48f8fdb`; `main` is 59 commits ahead. Rebasing
  the preservation branch would be a no-op. Re-landing its reverted changes
  would reintroduce the source break.
- Current `AscendantBackend` still exposes `runTurn`, `renameTimeline`, and
  `operatedTimelines()`. The Timeline-session API is not present on `main`.
- The preservation branch would reintroduce a large source change across Core
  and would replace the accepted repository ADR 0006 filename.

## Decision

Archive `codex/timeline-bound-backend-sessions` at `533e9f7`. Do not rebase or
re-land it. Keep its commits reachable through the
`archive/timeline-bound-backend-sessions` tag and through the existing `main`
history. The annotated tag is published as `e54b2a6` and dereferences to
`533e9f7`. Retiring the remote preservation branch is the last mechanical step
and removes no reachable commit.

Future multi-configuration work targets the flat `AscendantBackend` contract on
`main`. A future requirement for a session boundary must use a new decision
issue and ADR; it must not revive the archived branch by implication.

The separation reason is now part of the architecture history: #199 isolated a
completed experiment to let the flat contract remain the integration point for
runtime ownership and exact Turn observation. Those later changes are now
merged, and no fresh evidence requires the experiment's broader source break.

## Consequences

- #191–#194 remain valid historical delivery records, but their merged commits
  do not describe current `main` behavior.
- #199 remains the record of the reversion and branch preservation. This ADR
  supplies its missing rationale and archive condition.
- #243 and #246 target the flat backend contract. They must not depend on the
  preserved session branch.
- #242 remains independent of this decision. #244 and #245 target the flat
  contract through the composition and contribution seams.
- #185 no longer waits for a Timeline-session decision. Its observer seam is
  delivered on the flat contract, and #116 remains downstream of #185.
- The decision changes no source, wire, manifest, ACP, protocol-major, or
  persisted-identity contract.

## Rejected alternatives

- **RELAND:** The preservation tip is already an ancestor of current `main`.
  Rebasing would add no commits. Re-landing its reverted changes would
  reintroduce a source break that the merged runtime work does not require.
- **REDESIGN:** No fresh requirement identifies a part of the archived design
  that must be retained. A concrete future requirement can open a new design
  issue without preserving an ambiguous competing contract.

## Fitness

The repository checks this documentation decision with `make docs-check`,
`make verify`, and `git diff --check`. The architecture fitness tests included
in `make verify` continue to enforce the accepted runtime ownership and
backend-boundary decisions. No new exception is required.
