# Agent Instructions for Gnostic

## Canonical workflow

- GitHub Issues and the `Gnostic Roadmap` project are the sole planning record.
- Epics own outcomes and child work-plan issues; issue bodies preserve decisions, dependencies, acceptance criteria, and exact validation commands.
- Status flow is Backlog -> Ready -> In progress -> In review -> Done.
- Use one isolated worktree per issue and branch names shaped like `codex/420-stable-package-resolution`.
- Write a failing behavioral test before production code, observe the expected failure, implement minimally, and run the full gate.
- Request independent code review before merge. Fix every Critical or Important finding.
- Use Conventional Commits. Verify `pwd` and `git branch --show-current` immediately before commit or push.
- Open pull requests against `main`; merge only after required checks pass, then close the issue and remove the worktree.

## Build and test

- Never run native host `swift` commands. Use `make resolve`, `make build`, `make test`, `make verify`, or `make shell`.
- Broker-backed tests use the container's Mosquitto service and deterministic deadlines.
- `make verify` must fail when zero tests execute.
- Swift tests use Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`), not XCTest.

## Dependencies

- Commit released semantic-version pins for Axoloty and PositronicKit.
- A local-path override is allowed only for unreleased development and must be reverted before commit.
- Axoloty #420 blocks GNO-002 released-pin verification.
- Axoloty #418 and #419 block GNO-003.

## Swift conventions

- Swift 6 concurrency: `Sendable`, actor isolation, and explicit ownership by default.
- Use ErrorKit-compatible structured errors at public boundaries.
- Keep Gnostic transport/domain bridging downstream of PositronicKit; do not add Gnostic-specific APIs to PositronicKit.
- Keep Axoloty generic; do not add Gnostic, workspace, filesystem, or tool types upstream.
