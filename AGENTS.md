# Agent Instructions for Gnostic

Gnostic's canonical planning record is GitHub Issues plus the `Gnostic
Roadmap` project. Keep issue state, issue-body checklists, dependency text,
pull-request state, and Roadmap status truthful throughout the work. Use
[`CONTEXT.md`](CONTEXT.md) for domain vocabulary and
[`Documentation/Architecture/README.md`](Documentation/Architecture/README.md)
for accepted architecture decisions.

## Tracker preflight

Before planning material work:

1. Inspect the owning issue, open related issues, recently closed issues,
   merged pull requests, and the Roadmap.
2. Confirm that the work is not completed, superseded, or already owned by
   another active issue.
3. Record the implementation plan, pre-change evidence, dependencies, and
   validation commands in the owning issue. Do not commit planning documents,
   specifications, ticket copies, or planning directories to the repository.
4. Move the owning issue and its active epic to `In progress` before editing.

Material work has one owning issue and one isolated worktree. A mechanical-only
change may use the existing checkout when it changes no behavior or contract,
does not cross issue ownership, and is easy to review as one atomic diff. If a
change needs design judgment, production code, a dependency, a schema, a wire
contract, or more than one logical issue, it is material work and gets its own
worktree.

## Worktrees and branches

Create one worktree per issue and use a branch shaped like
`codex/<issue>-<short-description>`, for example
`codex/420-stable-package-resolution`. Keep unrelated changes out of the
worktree. Name commits with Conventional Commits.

Before every commit or push, run `pwd` and `git branch --show-current`, inspect
the staged and unstaged diff, and stage only the confirmed paths. Open pull
requests against `main`; create at most one pull request for an increment.

## Evidence by change class

- **Feature or bug:** write a failing behavioral test at the public seam,
  observe the failure, implement the smallest vertical slice, and retain the
  regression test.
- **Refactor:** record characterization evidence first, then preserve behavior
  through the same public seams.
- **Architecture or contract:** record the invariant, rejected alternative,
  dependency impact, and an architecture-fitness check in the owning issue.
- **Manifest, dependency, or build:** capture resolution/build compatibility
  and the affected smoke path; document any active external blocker.
- **Documentation or workflow:** add objective checks for links, commands,
  identifiers, and schemas where practical; record expected failures before
  correction. Do not invent a behavioral red test for prose-only work.

## Validation matrix

Run the narrowest applicable checks and the full gate before review:

| Change area | Required evidence |
| --- | --- |
| GnosticCore behavior | `make verify`, then the relevant smoke scenario |
| ACP or Turn behavior | `make verify`, `make runner-smoke`, and `make acp-smoke` when the ACP seam changes |
| Manifest or CLI | `make verify`, the relevant migration/configuration tests, and `make runner-smoke` when startup or routing changes |
| Container, Makefile, toolchain, or system dependency | `make container-smoke` plus the affected gate |
| Documentation or architecture | `make docs-check`, `make verify`, and `git diff --check` |
| Dependency resolution | `make resolve`, `make verify`, and the relevant smoke scenario |

Use the repository targets, not native host Swift commands. `make verify` must
fail when no tests execute. Broker-backed tests use the container's
deterministic Mosquitto service. Run additional focused checks when the owning
issue or reviewer identifies a risk.

## Dependencies and exceptions

Committed manifests use released semantic-version pins by default. A merged
upstream API may justify a temporary exact revision only when the owning issue
records the reason and replacement condition. A local-path dependency is
allowed only in uncommitted development, with the owning issue naming its
rationale and intended replacement. Local-path dependencies are forbidden in
mergeable state.

Architecture exceptions belong in
[`Documentation/Architecture/exceptions.json`](Documentation/Architecture/exceptions.json).
Each entry has a unique id, violated rule, exact scope, rationale, owning
issue, owner, and reconsideration condition. Wildcard target-wide scopes,
exceptions owned by closed issues, and silent scope broadening are prohibited;
each exception requires independent review.

## Review and tracker transitions

Request risk-based independent review before merge. The reviewer checks the
owning issue, constitutional documents, exception policy, production diff,
tests, and validation evidence. Fix every verified Critical or Important
finding, or record an explicit accepted rationale in the owning issue.

Use the status flow `Backlog -> Ready -> In progress -> In review -> Done`.
When a pull request is opened, move the issue to `In review` and keep its
checklist, dependencies, and Roadmap item aligned. After required checks pass
and the pull request merges, record the delivery summary, merge commit,
commands and outcomes, reviewer context, and finding dispositions; check the
delivered child in its epic, move the issue to `Done`, close it, remove resolved
blocker language, and remove the worktree. If no next reset child starts,
return the epic to `Ready`; otherwise leave it `In progress` with the named
active child.

## Swift and architecture conventions

Use Swift 6 concurrency deliberately: `Sendable`, actor isolation, and
explicit ownership are the default. Use Swift Testing (`import Testing`,
`@Test`, `#expect`, `#require`), not XCTest. Public boundaries use
ErrorKit-compatible structured errors.

Keep Gnostic transport and domain bridging downstream of PositronicKit. Keep
Axoloty generic: it must not gain Gnostic, Workspace, filesystem, or tool
types. Do not add Gnostic-specific APIs to PositronicKit. Read the architecture
index and `CONTEXT.md` before changing a boundary, and update the owning issue
when an accepted decision or exception changes.
