# Agent Instructions for Gnostic

## Canonical workflow

- GitHub Issues and the `Gnostic Roadmap` project are the sole planning record.
- Do not commit local plans, specifications, tickets, or planning directories. Record designs, decisions, implementation plans, dependencies, acceptance criteria, and exact validation commands in the owning GitHub issue instead.
- Before planning new work, inspect open issues, recently closed issues, merged pull requests, and the Roadmap so completed or superseded work is not planned again.
- Epics own outcomes and child work-plan issues. Treat historical `design-reference` issues as context, not active requirements.
- Keep the tracker truthful throughout the work: issue state, issue-body status and checklists, dependency text, and Roadmap status must agree with the code and pull-request state.
- Status flow is Backlog -> Ready -> In progress -> In review -> Done.
- Use one isolated worktree per issue and branch names shaped like `codex/420-stable-package-resolution`.
- Write a failing behavioral test before production code, observe the expected failure, implement minimally, and run the full gate.
- Request independent code review before merge. Fix every Critical or Important finding.
- Use Conventional Commits. Verify `pwd` and `git branch --show-current` immediately before commit or push.
- Open pull requests against `main`; merge only after required checks pass. After merge, update the issue body and Roadmap to Done, close the issue and any delivered epic, remove resolved blocker language, and remove the worktree.

## Current baseline

- `main` contains the standalone Swift package, `GnosticCore`, and the `gnostic-runner` executable.
- The completed PoC projects PositronicKit Agent, Timeline, and Workspace objects; discovers, inspects, imports, and attaches an unambiguous advertised Workspace; invokes its tools through Axoloty unary Call/Return; and readvertises the changed Timeline.
- The deterministic runner fixture covers discovery, approved attachment, `list_files`, `read_file`, and `workspace_echo` through Mosquitto without LLM or broker credentials.
- `Package.swift` pins Axoloty `0.3.0` and PositronicKit `3.4.0` exactly. These releases include the former Axoloty #418, #419, and #420 blockers.
- The verified baseline is 73 Swift Testing tests in 9 suites plus the passing runner fixture smoke scenario (includes the GNO-005–GNO-010 narrative/context stack).
- Current builds show one external warning family from the PositronicKit dependency: SwiftPM cannot locate the optional `pkfastembed` pkg-config file for PK's `CPKFastEmbed` system target (and macOS hosts additionally report pkg-config being absent). This is PositronicKit-owned (its `Package.swift` declares `pkgConfig: "pkfastembed"` unconditionally) and is not resolved from this repository; do not vendor a copy of the dependency to silence it, and do not mistake it for a Gnostic validation failure. All warnings attributable to Gnostic sources and tests are resolved.

## Build and test

- Never run native host `swift` commands. Use the repository targets, including `make resolve`, `make build`, `make test`, `make verify`, `make runner-smoke`, `make container-smoke`, and `make shell`.
- Broker-backed tests use the container's Mosquitto service and deterministic deadlines.
- `make verify` must fail when zero tests execute.
- For production-code changes, the full local gate is `make verify` followed by `make runner-smoke`.
- Run `make container-smoke` when changing the container image, command harness, toolchain, or system dependencies.
- Swift tests use Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`), not XCTest.

## Dependencies

- Commit released semantic-version pins for Axoloty and PositronicKit.
- A local-path override is allowed only for unreleased development and must be reverted before commit.
- Record active external blockers in the owning GitHub issue and remove them when a released dependency resolves them.

## Swift conventions

- Swift 6 concurrency: `Sendable`, actor isolation, and explicit ownership by default.
- Use ErrorKit-compatible structured errors at public boundaries.
- Keep Gnostic transport/domain bridging downstream of PositronicKit; do not add Gnostic-specific APIs to PositronicKit.
- Keep Axoloty generic; do not add Gnostic, workspace, filesystem, or tool types upstream.
