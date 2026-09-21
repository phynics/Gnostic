# ADR 0011 — External ACP agents as Ascendant backends

## Status

Accepted target architecture. Delivery is tracked by
[Epic #288](https://github.com/phynics/Gnostic/issues/288) (External ACP agents
as Ascendant backends), whose child GNO-ACPC-008 is
[#296](https://github.com/phynics/Gnostic/issues/296). Delivery is checked by
[Epic #140](https://github.com/phynics/Gnostic/issues/140) and
[RESET-001 #145](https://github.com/phynics/Gnostic/issues/145) documentation
and architecture gates.

This record is a boundary decision only. It does not deliver the ACP client,
the backend target, or any wire contract. It supersedes the "external frontend
only" disposition of [#81](https://github.com/phynics/Gnostic/issues/81) for the
backend direction; the ACP frontend (`gnostic acp`) remains and is not
deprecated.

## Context

`gnostic acp` already exposes Gnostic Ascendants as an ACP **agent** over stdio,
and `RemoteTurnClient` is an Axoloty client rather than an ACP client. There is
no outbound ACP connection in `Sources`.

[#81](https://github.com/phynics/Gnostic/issues/81) evaluated ACP as Gnostic's
agent boundary and resolved on 2026-08-10:

> ACP is adopted as Gnostic's external frontend boundary only; Axoloty, MQTT
> discovery, PositronicKit, Ascendants, Timelines, and Workspaces remain the
> internal domain.

[Epic #288](https://github.com/phynics/Gnostic/issues/288) incubates the
inverse direction: an external ACP agent process acts as an Ascendant Backend.
The first targets are opencode, OpenAI Codex (`codex-acp`), and Claude Agent
(`claude-agent-acp`). ACP v2's accepted RFD removes the client `fs/*` and
`terminal/*` surfaces, so an agent executes its own tools. That makes
agent-owned tool execution the ACP baseline rather than a convenience.

[#81](https://github.com/phynics/Gnostic/issues/81) itself listed the ownership
questions this decision must answer: who owns Turn identity and retry safety,
who owns session and Timeline identity, who owns the tool loop, and how
permission decisions cross the boundary. [ADR 0002](0002-gnostic-identity-vs-backend-state.md)
and `CONTEXT.md` already fix the identity split; this record fixes the backend
direction and the tool and permission split.

Two boundary facts constrain the shape of the decision:

- `GnosticCore` declares iOS, and `Foundation.Process` cannot land in Core.
- [ADR 0005](0005-core-positronic-dependency-boundary.md) defers extracting the
  bundled Positronic adapter until "a second backend is shipped". The parallel
  Letta evaluation ([#246](https://github.com/phynics/Gnostic/issues/246))
  recorded `PROTOTYPE`, not shipped, and left that trigger deferred.

## Decision

External ACP agents may act as Ascendant backends. A Gnostic Node may host an
Ascendant whose backend is an external ACP agent process reached over ACP
stdio, selected per Ascendant from the manifest v2 backend envelope.

### Ownership invariant

Gnostic retains, unchanged:

- Ascendant and Timeline identity, advertisement, and routing (ADR 0002,
  `CONTEXT.md`).
- Turn admission, per-Timeline serialization, idempotency and replay, and the
  client Turn identity (`clientTurnID`) contract (ADR 0006).
- Permission correlation: an ACP `session/request_permission` request bridges
  into `AscendantBackendPermissionService`, and the decision returned to the
  agent is the Gnostic-mediated decision.
- Backend lifecycle supervision, quarantine, and bounded reconstruction
  (ADR 0006).

The external ACP agent owns model and tool execution. It executes its own tool
loop, including any file or terminal tools its own runtime provides. One agent
process serves one Ascendant, and one ACP session projects one Gnostic Timeline.
The ACP session is backend-private state; it cannot redefine or erase Gnostic
Timeline identity.

Gnostic Workspace tools are **not** available to these backends. This decision
does not route tool calls through `AscendantBackendWorkspaceService`, and the
backend does not advertise the Workspace capability. Workspace attachment
intent is still recorded, because Gnostic owns intent independently of backend
capability (ADR 0002), and an intended attachment resolves to effective status
`unsupported` for this backend rather than `unavailable`.

### Dependency and target boundary

- Exactly one optional downstream target outside `GnosticCore` owns the ACP
  client and the process transport. It is macOS-only because it uses
  `Foundation.Process`.
- Exactly one community Swift ACP SDK is used, pinned to an exact released
  semantic version. The bake-off in
  [GNO-ACPC-001 #289](https://github.com/phynics/Gnostic/issues/289) selects and
  pins it; `aptove/swift-sdk` is the preferred candidate. No unreleased
  revision pin and no `branch` or `from:` range is allowed.
- `GnosticCore` gains no ACP, subprocess, or SDK dependency. Core continues to
  see only the flat `AscendantBackend` contract
  ([ADR 0007](0007-timeline-bound-backend-session-contract-disposition.md)).
- The kind (`acp-client`) is registered through the composition source from
  [GNO-MULTI-001 #242](https://github.com/phynics/Gnostic/issues/242), not in
  Core. Composition stays static, as
  [ADR 0009](0009-multi-configuration-ascendant-hosting.md) requires: no
  dynamic plugin discovery, hot swap, or live manifest reload.
- Configuration uses the existing backend envelope: settings such as the agent
  command, arguments, and working directory, plus one secret for the agent
  credential. No new wire, manifest-shape, or protocol-major contract is
  introduced.

### Architecture fitness check

The following must hold and must be guarded by the architecture fitness tests
run by `make verify`:

- No file under `Sources/GnosticCore` imports the ACP SDK or names an ACP type.
- No file under `Sources/GnosticCore` spawns a process (`Foundation.Process`,
  `NSTask`, `posix_spawn`).
- The optional target reaches the host only through `AscendantBackend` and
  `AscendantBackendServices`, and registers only through the composition
  source.
- The existing Positronic import inventory test
  (ADR 0005) and the experiment-target test
  (ADR 0009) continue to pass unchanged.

The target's own boundary test, added with the target, fails if Core gains an
SDK or process dependency. Core's existing import-inventory test already pins
Core's dependency set, so a new Core import fails the same gate.

## Dependency impact

One optional macOS target and one exact-pinned community SDK. `GnosticCore` and
`Package.resolved` change only by the added SDK entry; the Core target's
dependency list is unchanged. The SDK's transitive graph must stay within the
dependencies already accepted for downstream targets (for example `swift-log`
and `swift-collections`); GNO-ACPC-001 records the resolved graph before
GNO-ACPC-002 adds the dependency.

No architecture rule is bent. `exceptions.json` is unchanged, and no new
exception entry is required. If implementation later needs a Core change, or a
looser dependency pin, that is a new architecture decision with its own issue
and, if a rule is violated, its own reviewed exception entry.

## Re-evaluation of the ADR 0005 extraction trigger

[ADR 0005](0005-core-positronic-dependency-boundary.md) defers extracting the
bundled Positronic adapter until "a second backend is shipped". This decision
authorizes a second backend kind, but neither backend is shipped by this record:

- The Letta evaluation ([#246](https://github.com/phynics/Gnostic/issues/246))
  recorded `PROTOTYPE`. An optional, experimental, fixture-backed prototype is
  not a shipped backend.
- The ACP backend is a target architecture in [Epic #288](https://github.com/phynics/Gnostic/issues/288),
  not a delivered kind.

The trigger therefore remains deferred. It must be explicitly re-evaluated when
either backend ships as a supported kind, and the outcome recorded in ADR 0005
or a superseding decision. The extraction question is whether the Positronic
adapter should move to a downstream target so Core keeps only the flat contract
and the composition seam.

The ACP backend does not consume `AscendantBackendWorkspaceService` and shares
no code with the Positronic adapter, so this decision adds no pressure to that
shared boundary by itself. A second shipped backend, not a second planned one,
is the evidence ADR 0005 asked for.

## Rejected alternatives

- **Require `AscendantBackendWorkspaceService` routing.** This would force every
  ACP agent's tool calls back through Gnostic Workspace execution and would
  limit eligible agents to delegating adapters such as Letta's client tools.
  ACP agents execute their own tools, and ACP v2 removes the client tool
  surfaces, so the requirement would exclude the intended targets and buy no
  authority Gnostic does not already keep through permission correlation.
- **Gnostic acting as an ACP proxy.** Interposing a Gnostic-owned ACP hop
  between the external agent and the Gnostic frontend would make Gnostic both an
  ACP client and an ACP agent on the same connection, add a failure and latency
  hop with no identity benefit, and blur the frontend/backend boundary
  [ADR 0001](0001-axoloty-native-multi-backend-host.md) keeps explicit. The
  backend connects to the agent process directly, and the frontend stays a
  separate Gnostic surface.
- **Remote HTTP/WebSocket ACP transport.** ACP v1 standardizes stdio. A remote
  transport adds a network trust boundary, credential distribution, endpoint
  discovery, and reconnect semantics that ACP does not define and this epic
  lists as a non-goal. The transport stays process-local stdio.
- **Put the ACP client or `Foundation.Process` in `GnosticCore`.** Core declares
  iOS, and [ADR 0009](0009-multi-configuration-ascendant-hosting.md) keeps
  experiment targets outside Core. A Core dependency would couple every build
  and every platform to an experimental backend.
- **Require external agents to consume Gnostic Workspace attachment.** A backend
  that cannot advertise the Workspace capability must not fabricate one, and
  attachment intent must not silently become a routing error. Recording intent
  and reporting `unsupported` keeps the Gnostic relationship honest.
- **Dynamic plugin discovery or live manifest reload.** ADR 0009 fixes static
  composition. ACP adds no reason to reverse that.

## Consequences

- Gnostic can host an external ACP agent as an Ascendant Backend without
  weakening identity, routing, Turn admission, replay, or permission mediation.
- ACP is no longer only a frontend boundary. The `#81` sentence above is
  superseded for the backend direction; its frontend decision still stands, and
  `gnostic acp` is not deprecated.
- Operators of an ACP-backed Ascendant cannot use Gnostic Workspace tools.
  Workspace attachment intent is recorded but resolves to `unsupported`.
- The repository will carry one optional macOS target and one exact-pinned
  community SDK. Neither is a Core or production dependency.
- ADR 0005's extraction trigger stays deferred, now with two concrete second
  backend candidates recorded rather than an assumption.
- No wire, manifest-shape, protocol-major, or persisted-identity contract
  changes. `gnostic acp`, the ACP frontend, and the flat `AscendantBackend`
  contract are untouched.

## Reconsideration triggers

Reconsider this decision when:

- a stable ACP v2 specification ships and the client negotiates it;
- ACP standardizes a durable client-supplied session or Turn identifier that
  replaces or conflicts with the Gnostic `clientTurnID` replay contract;
- an intended agent cannot request permissions through ACP, which removes the
  Gnostic mediation point (the reason pi is deferred);
- an agent needs client-side `fs/*` or `terminal/*`, which would make Workspace
  routing necessary again;
- a shipped second backend makes ADR 0005 extraction concrete; or
- remote transport becomes a real requirement with a defined trust model.

## Fitness

This record is checked by `make docs-check`, `make verify`, and
`git diff --check`. `make verify` runs the architecture fitness tests that pin
Core's dependency boundary. The decision adds no Core dependency and no
exception; if a Core dependency or a looser SDK pin becomes necessary, the
owning issue must record the reason and `exceptions.json` must gain a reviewed
entry with an exact scope, owner, and reconsideration condition.

## Links

- [#296 — GNO-ACPC-008 architecture decision](https://github.com/phynics/Gnostic/issues/296)
- [Epic #288 — External ACP agents as Ascendant backends](https://github.com/phynics/Gnostic/issues/288)
- [GNO-ACPC-001 #289 — evaluate community Swift ACP SDKs](https://github.com/phynics/Gnostic/issues/289)
- [#81 — evaluate ACP as Gnostic's external and internal agent boundary](https://github.com/phynics/Gnostic/issues/81)
- [#246 — Letta as the first non-Positronic Ascendant backend](https://github.com/phynics/Gnostic/issues/246)
- [ADR 0001 — Axoloty-native multi-backend host](0001-axoloty-native-multi-backend-host.md)
- [ADR 0002 — Gnostic identity versus backend state](0002-gnostic-identity-vs-backend-state.md)
- [ADR 0005 — Core PositronicKit dependency boundary](0005-core-positronic-dependency-boundary.md)
- [ADR 0006 — Runtime effect ownership and terminal observation](0006-runtime-effect-ownership-and-terminal-observation.md)
- [ADR 0007 — Timeline-bound backend session contract disposition](0007-timeline-bound-backend-session-contract-disposition.md)
- [ADR 0009 — Multi-configuration Ascendant hosting on one Node](0009-multi-configuration-ascendant-hosting.md)
- [Epic #140](https://github.com/phynics/Gnostic/issues/140)
- [RESET-001 #145](https://github.com/phynics/Gnostic/issues/145)
