# Agent instructions for Gnostic

GitHub Issues and the `Gnostic Roadmap` project are the planning record. Keep
issue, checklist, dependency, pull request, and Roadmap state aligned.

Use [`CONTEXT.md`](CONTEXT.md) for domain terms. Read the
[`architecture index`](Documentation/Architecture/README.md) before changing a
domain or package boundary. It links accepted decisions and exception rules.

## Start work

Before material work:

1. Inspect the owning issue, related open and recently closed issues, merged
   pull requests, and the Roadmap.
2. Confirm that the work is not complete, superseded, or owned elsewhere.
3. Record the plan, pre-change evidence, dependencies, and validation commands
   in the owning issue.
4. Move the issue and its active epic to `In progress`.

Material work includes behavior, contracts, schemas, dependencies,
architecture, and design decisions. Give it one owning issue and one isolated
worktree. Use the current checkout only for a mechanical, one-issue diff that
changes no behavior or contract.

Do not commit plans, specifications, ticket copies, or planning directories.
Name branches `codex/<issue>-<short-description>`. Keep unrelated changes out.
Use Conventional Commits.

Before each commit or push, run `pwd` and `git branch --show-current`. Then
inspect staged and unstaged changes. Stage only confirmed paths.

Open pull requests against `main`. Create at most one pull request per
increment.

## Produce evidence

- **Feature or bug:** Observe a failing behavioral test at the public seam.
  Implement the smallest vertical slice. Keep the regression test.
- **Refactor:** Record characterization evidence first. Preserve the same
  public behavior.
- **Architecture or contract:** Record the invariant, rejected alternative,
  dependency impact, and fitness check in the owning issue.
- **Manifest, dependency, or build:** Prove resolution and build compatibility.
  Exercise the affected smoke path. Record external blockers.
- **Documentation or workflow:** Check links, commands, identifiers, and
  schemas where practical. Record expected failures before correction. Do not
  invent a behavioral red test for prose-only work.

## Validate

Run the narrowest applicable checks and the full gate before review:

| Change area | Required evidence |
| --- | --- |
| GnosticCore behavior | `make verify`, then the relevant smoke scenario |
| ACP or Turn behavior | `make verify`, `make runner-smoke`, and `make acp-smoke` when the ACP seam changes |
| Manifest or CLI | `make verify`, focused migration or configuration tests, and `make runner-smoke` when startup or routing changes |
| Container, Makefile, toolchain, or system dependency | `make container-smoke` plus the affected gate |
| Documentation or architecture | `make docs-check`, `make verify`, and `git diff --check` |
| Dependency resolution | `make resolve`, `make verify`, and the relevant smoke scenario |

Use repository targets instead of native host Swift commands. `make verify`
must fail when no tests execute. Broker-backed tests use the container's
deterministic Mosquitto service. Add focused checks for risks named by the issue
or reviewer.

The `verify` workflow runs `make container-smoke`, `make verify`,
`make runner-smoke`, and `make acp-smoke` for pull requests and pushes to
`main`. It uses the same `.devcontainer/Dockerfile` image as local validation.
Run local checks before opening a pull request. Treat the workflow as a
backstop, not as a substitute for local evidence.

## Manage dependencies and exceptions

Pin committed dependencies to released semantic versions. A merged upstream
API may use a temporary exact revision only when the issue records the reason
and replacement condition.

Use local-path dependencies only during uncommitted development. Record their
rationale and replacement in the issue. Remove them before review.

Follow the architecture index for exception rules. Record approved exceptions
in [`exceptions.json`](Documentation/Architecture/exceptions.json). Require
independent review for each exception.

## Review and finish

Request risk-based independent review before merge. Review the issue,
constitutional documents, exception policy, production diff, tests, and
evidence. Fix every verified Critical or Important finding, or record an
explicit acceptance rationale in the issue.

Use `Backlog -> Ready -> In progress -> In review -> Done`. Move the issue to
`In review` when its pull request opens. Keep its checklist, dependencies, and
Roadmap item aligned.

After required checks pass and the pull request merges:

1. Record the delivery summary, merge commit, command outcomes, reviewer
   context, and finding dispositions.
2. Update the parent epic checklist, dependencies, and blockers.
3. Move the issue to `Done` and close it.
4. Remove the worktree.

Set the epic to `Ready` when no child issue is active. Otherwise, keep it `In
progress` and name the active child.

## Follow Swift and architecture conventions

Use Swift 6 concurrency deliberately. Make ownership and actor isolation
explicit. Add `Sendable` where values cross isolation boundaries.

Use Swift Testing with `import Testing`, `@Test`, `#expect`, and `#require`.
Do not use XCTest. Use ErrorKit-compatible structured errors at public
boundaries.

Keep Gnostic Axoloty-native. Keep Axoloty free of Gnostic, Workspace,
filesystem, and tool types. Keep native PositronicKit values inside the
adapters and bridges allowed by ADR 0005. Keep Gnostic-owned contracts free of
native PositronicKit values. Do not add Gnostic-specific APIs to PositronicKit.

Update the owning issue and architecture record when an accepted decision or
exception changes.
