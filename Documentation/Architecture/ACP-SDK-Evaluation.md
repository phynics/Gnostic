# ACP SDK evaluation

This record satisfies GNO-ACPC-001 for the external ACP backend prototype. It
is an evaluation record, not a public Gnostic protocol contract.

## Outcome

**PROTOTYPE** — use `aptove/swift-sdk` at the exact released tag `v0.1.16`.

The package is Apache-2.0 licensed. Its package name is `ACP`, and the client
target consumes the `ACP` and `ACPModel` products. The SDK supports Swift 6,
macOS process-local stdio, ACP initialization, session creation, prompts,
streamed `session/update` notifications, permission callbacks, session list,
session load/resume, and `session/cancel`.

The production target must use an exact dependency pin:

```swift
.package(url: "https://github.com/aptove/swift-sdk.git", exact: "0.1.16")
```

The SDK is optional and downstream. It must not be added to `GnosticCore`.

## Dependency graph

The `v0.1.16` package declares these direct dependencies:

- `swift-log`, used by the ACP runtime.
- `swift-collections`, used by the model and runtime.

No other direct dependency is declared by the SDK package. The Gnostic target
must use the existing `swift-log` pin where SwiftPM permits it and must record
the resolved graph in `Package.resolved` before the backend target is reviewed.

## Candidate comparison

| Candidate | Pin | License | Result |
| --- | --- | --- | --- |
| `aptove/swift-sdk` | `v0.1.16` | Apache-2.0 | Selected: exact released pin, Swift 6 package, client/session/stdio APIs match the backend seam. |
| `wiedymi/swift-acp` | `v0.1.0` | MIT | Rejected for this prototype: one released tag and the README install example requests `1.0.0`, so the documented package range does not match the available release. |

## Protocol and boundary checks

The selected SDK's client API provides the required shape:

1. `ClientConnection.connect()` sends `initialize` and stores the negotiated
   protocol and agent capabilities.
2. `createSession`, `prompt`, `listSessions`, `loadSession`, and
   `resumeSession` cover the Timeline mapping seam. Session list and resume are
   marked unstable by the SDK, so the backend treats them as optional recovery
   helpers rather than the source of Gnostic Timeline identity.
3. `Client.onSessionUpdate` receives streamed updates without exposing SDK
   values through `GnosticCore`.
4. `ClientSessionOperations.requestPermissions` is asynchronous, so an ACP
   permission request can await Gnostic's permission service.
5. `StdioTransport` uses newline-delimited JSON over file handles. The optional
   backend target owns `Foundation.Process` and connects the child's stdout and
   stdin to this transport. Child stderr remains outside protocol stdout.

The SDK's default client examples advertise filesystem and terminal services.
The Gnostic backend must advertise neither. ACP agents own their tools for this
prototype; only `session/request_permission` crosses into Gnostic mediation.

## Handshake evidence and blocker

The repository already contains an ACP v1 fixture path, but it exercises the
existing `gnostic acp` frontend and does not prove the new Swift client
dependency. The host checkout has Node and the three agent launch commands, but
does not have a host `swift` executable. No authenticated live agent session is
available in this environment. Therefore this record does not claim a live
Swift-client handshake or a redacted real-agent transcript.

Replacement condition: run the SDK client probe on a macOS or Swift-enabled
runner with each of these commands available and authenticated:

- `opencode acp` after `opencode auth login`.
- `npx @agentclientprotocol/codex-acp` with a supported Codex credential.
- `claude-agent-acp` with Claude Code login or `ANTHROPIC_API_KEY`.

The fixture-backed handshake and all behavioral proof remain required in
GNO-ACPC-003. Real-agent evidence remains required in GNO-ACPC-007.

## Rejected implementation direction

The backend must not copy the repository's existing ACP frontend JSON-RPC
implementation into `GnosticCore`. That would violate ADR 0011's dependency
boundary and would make Core own a macOS process transport. The selected SDK is
used only by the optional downstream backend target.
