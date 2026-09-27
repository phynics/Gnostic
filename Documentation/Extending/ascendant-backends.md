# Implementing an Ascendant backend

An Ascendant backend is the component that actually runs a Turn. Gnostic owns
identity, routing, Timelines, and replay; the backend owns model and tool work.
This guide covers the contract you implement and how to register it.

The complete worked example is
[`Tests/GnosticCoreTests/ExampleBackendTests.swift`](../../Tests/GnosticCoreTests/ExampleBackendTests.swift).
It lives in the test target so it cannot drift from the API.

## The mandatory contract

Conform to `AscendantBackend`. It is `@MainActor` and deliberately contains no
transport, provider-native identity, or Coaty types.

| Member | Called when |
| --- | --- |
| `identity` | Read whenever Gnostic projects the Ascendant. |
| `validateConfiguration()` | After Gnostic checks the envelope shape, before the backend is published. |
| `operatedTimelines()` | During assembly and whenever Gnostic reconciles Timelines. |
| `createTimeline(id:title:)` | When Gnostic adopts a new Timeline. Adopt the identifier it supplies. |
| `removeTimeline(id:)` | When a Timeline is removed. Removing an unknown Timeline is not an error. |
| `renameTimeline(id:title:)` | When a Timeline title changes. |
| `runTurn(_:updates:)` | Once per admitted Turn. |
| `cancel()` | When the running Turn should stop. Return once cancellation is requested. |
| `shutdown()` | Once, and not concurrently with a Turn. |

## `runTurn` delivers output twice, for two audiences

This is the part most easily got wrong. Incremental output goes to the
`updates` sink as it is produced, and the **final assistant text** is the
return value. It is not an identifier.

```swift
let reply = "echo: \(request.message)"
try await updates.append(
    AscendantBackendUpdate(kind: AscendantTurnUpdateKind.assistantText.rawValue, text: reply)
)
try await updates.append(
    AscendantBackendUpdate(kind: AscendantTurnUpdateKind.completion.rawValue, terminal: true)
)
return reply
```

A client watching the live stream reads the sink; a caller that only awaits the
result reads the return value. A Turn that completes without producing text
returns an empty string.

Update kinds are declared by `AscendantTurnUpdateKind`; tool and permission
statuses by `AscendantToolStatus` and `AscendantPermissionStatus`. Use them
rather than string literals.

## Failing correctly

The distinction Gnostic acts on is whether your backend can still serve.

- `AscendantBackendError.terminal(_:)` wraps `AscendantBackendTerminalFailure`.
  The Turn failed; the backend is still usable. This is the ordinary case for
  model and tool failures.
- `AscendantBackendError.cancelled` for a cancelled Turn.
- `AscendantBackendError.timelineNotFound(_:)` when the Timeline is not yours.
- `AscendantBackendError.lifecycleUnusable(_:)` wraps
  `AscendantBackendLifecycleFailure` and means the backend can no longer serve
its Ascendant at all. `AscendantBackendSupervisor` responds by quarantining
  it and attempting one bounded reconstruction. Do not use it for ordinary
  failures.

An explicit cancellation is scoped to a Timeline and an identified client Turn.
The runtime calls the optional `AscendantBackendTurnCancellation` capability
when the backend implements it. `cancel()` remains backend-wide and is reserved
for retirement and shutdown; do not use it to cancel one user's Turn when a
backend can serve multiple Timelines concurrently.

## Optional capabilities

The mandatory contract never depends on these. Implement them only if they
apply.

- `AscendantBackendWorkspaceService` — tool-call access to attached Workspaces.
  Supplied through `AscendantBackendServices`.
- `AscendantBackendWorkspaceFileService` — direct file access. Separate,
  because a remote capability Workspace need not be a filesystem.
- `AscendantBackendWorkspaceCapability` — attach, detach, and enumerate tools.
- `AscendantBackendPermissionService` — host mediation for tool approval.
  Returns `AscendantPermissionDecision`, which distinguishes a denial from a
  host failure.
- `AscendantBackendOptionalCapability` — marker for services meaningful to one
  implementation only, resolved with `AscendantBackendServices.capability(_:)`.

A backend that consumes none of these can take `AscendantBackendServices.empty`
without manufacturing no-op services.

## Registering the kind

Register against the manifest's `backend.kind`:

```swift
var adapters = NodeRuntimeAdapters.default
adapters.ascendants.registerBackend(
    kind: "example-echo",
    settings: AscendantBackendSettingsSchema(keys: [
        .init(name: "greeting", summary: "Text prefixed to every reply."),
        .init(name: "apiKey", summary: "Upstream credential.", isSecret: true),
    ])
) { ascendant, backend, services, timelines in
    EchoAscendantBackend(ascendant: ascendant, timelines: timelines)
}
```

Literal keys cover fixed settings. A backend that accepts one environment
variable per key can also declare dynamic key families. The prefix determines
the family; the suffix must be a valid environment-variable name. Secret
families are stored in `backend.secrets` and stay structurally redacted.

`registerBackend(kind:settings:factory:)` is the only supported selection
point. The `settings` schema is optional but strongly recommended: it is what
lets `gnostic config backend keys <ascendant-id>` list your keys and reject a
mistyped one at write time instead of at startup.

`AscendantAdapterRegistry.registeredKinds` enumerates what a registry can
build, and `settingsSchema(for:)` returns a kind's keys.

## How `kind` reaches your factory

1. `gnostic config ascendant add "Name" --kind example-echo` writes
   `backend.kind` into the manifest. The kind must already be registered.
2. `gnostic config backend set <ascendant-id> greeting "hi"` writes settings;
   `set-secret` writes secrets, reading the value from standard input.
3. At startup `NodeAssembly` validates every configured kind against the
   registry, then calls your factory with the Ascendant, the envelope, the host
   services, and the Timelines it operates.
4. Gnostic calls `validateConfiguration()` before publishing the backend.

Configuration commands consult the default registrations only. A kind
registered solely inside a custom running host can be built but not configured
through the CLI. The production CLI composition is shared by `serve` and
`config`, and includes the optional `letta` and `acp-client` kinds.

### Using an ACP agent backend

The optional `acp-client` kind launches an external ACP agent and maps one ACP
session to each Gnostic Timeline. It executes Turns and forwards their updates.

Each Ascendant launches one agent process. Each Gnostic Timeline maps to a
private ACP session owned by that process. Gnostic keeps Timeline identity,
Turn admission, replay, and permission correlation. The backend does not expose
Gnostic Workspace tools or advertise Workspace capabilities; the agent runs
its own filesystem, terminal, and other tools. A configured Workspace
attachment remains intent only and does not make Gnostic tools available to
this backend. Review each agent's own tool and filesystem access before running
it.

#### Launch recipes and authentication

Install the agent and adapter in the same runtime environment that runs
`gnostic serve`. Do not put credentials in `args`, `env`, the manifest, or a
fixture. The child can use credentials in its normal home directory because
`HOME` is inherited; only explicitly configured variables are added to its
environment.

Gnostic's Swift ACP client uses `aptove/swift-sdk` pinned to exact version
`0.1.16`. The backend owns its process stdio transport because SDK
`StdioTransport.start()` blocks before ACP initialization in this release; the
protocol framing and models still come from the SDK. Re-evaluate this
target-local workaround when a later released SDK no longer blocks in `start()`.

| Agent | Command and arguments | Authentication | Adapter/package pin and known limits |
| --- | --- | --- | --- |
| opencode | `opencode acp` | Run `opencode auth login` first. The login is stored in the user's opencode auth store. | Native ACP in `opencode-ai` (1.18.32 observed during this guide's smoke setup; Gnostic does not pin the external CLI). It executes its own tools and does not use Gnostic Workspace tools. The observed file-tool Turn did not request Gnostic permission. |
| Codex | `npx --yes @agentclientprotocol/codex-acp@1.13.1` | Use the existing ChatGPT login, or configure `CODEX_API_KEY` / `OPENAI_API_KEY` as a secret setting. | `@agentclientprotocol/codex-acp` 1.13.1, pinned in the command to avoid npm tag drift. This adapter fronts Codex App Server; npm and the package registry are required when `npx` must download it. In this Linux container, Codex's sandbox could not create a user namespace on its first attempt, then retried the tool call successfully. Codex owns its approval and sandbox modes; Gnostic mediates only ACP `session/request_permission` calls and does not configure Codex's local policies. See the [Codex ACP adapter documentation](https://github.com/agentclientprotocol/codex-acp#readme). |
| Claude Agent | `claude-agent-acp` | Use an existing Claude Code login, or configure `ANTHROPIC_API_KEY` as a secret setting. | `@agentclientprotocol/claude-agent-acp` 0.64.0 observed for this guide. This adapter fronts the Claude Agent SDK; its observed `allow_always` / `allow` / `reject` permission options are not supported by the current Gnostic bridge, which fails closed. |

To select an agent, configure its executable and arguments on the Ascendant.
For example, OpenCode uses:

```sh
gnostic config ascendant add "OpenCode" --kind acp-client
gnostic config backend set <ascendant-id> command opencode
gnostic config backend set <ascendant-id> args '["acp"]'
gnostic config backend set <ascendant-id> cwd "$PWD"
```

For Codex, set `command` to `npx` and `args` to
`["--yes","@agentclientprotocol/codex-acp@1.13.1"]`. For Claude Agent, set
`command` to `claude-agent-acp` and `args` to `[]`.

Use `set-secret` for API keys. This example reads the key from the shell without
putting its value in command history:

```sh
printf '%s' "$CODEX_API_KEY" | gnostic config backend set-secret <ascendant-id> env-secret.CODEX_API_KEY
```

Use `env-secret.OPENAI_API_KEY` instead when supplying that key, or
`env-secret.ANTHROPIC_API_KEY` for Claude Agent. `config show` redacts these
values. `env.<NAME>` and the JSON `env` setting are for non-secret strings only.
The three agents do not need an API-key setting when their existing login is
available to the child process.

`args` and `env` are JSON-encoded strings because the generic `config backend
set` command stores one string per key. The `env.<NAME>` family stores one plain
environment variable per setting, and the `env-secret.<NAME>` family stores
one secret per secret key:

```sh
gnostic config ascendant add "OpenCode" --kind acp-client
gnostic config backend set <ascendant-id> command opencode
gnostic config backend set <ascendant-id> args '["acp"]'
gnostic config backend set <ascendant-id> cwd "$PWD"
gnostic config backend set <ascendant-id> env '{"MODE":"safe"}'
gnostic config backend set <ascendant-id> env.LOG_LEVEL debug
printf '%s' "$AGENT_API_TOKEN" | gnostic config backend set-secret <ascendant-id> env-secret.API_TOKEN
gnostic config backend set <ascendant-id> displayName "OpenCode"
```

The `env` object and `env.<NAME>` settings accept non-secret strings only. Keep
credentials in `env-secret.<NAME>` and enter them through `set-secret`; these
values are stored under `backend.secrets` and are redacted by `config show`.
The CLI lists both families and rejects invalid variable names, unknown keys,
and attempts to write a family through the wrong setter. The ACP backend merges
the plain and secret values into the future child-process environment, but this
configuration-only increment does not launch a process or log values. A
variable cannot be declared in more than one of `env`, `env.<NAME>`, and
`env-secret.<NAME>`.

#### Cancellation

When a user sends ACP `session/cancel` through `gnostic acp`, the frontend sends
the matching Timeline ID and client Turn ID to the serving runtime. The runtime
requests cancellation only for that admitted Turn. The ACP backend sends
`session/cancel` to the external agent session mapped to that Timeline, settles
the Turn as cancelled, and ignores later updates for that Turn. A positive
runtime acknowledgement means the matching in-flight Turn accepted the cancel
request; it does not prove the agent stopped. ACP agents may ignore
`session/cancel` or continue work briefly before stopping. The frontend cannot
guarantee cancellation for agents that do not honour this request. Cancelling
the local Swift task or disconnecting a caller alone does not cancel an
admitted Turn. Backend-wide `cancel()` remains reserved for retirement and
shutdown.

#### Opt-in live smoke

Run exactly one real Turn in an environment where the selected agent command,
its persisted login or a supplied API key, SwiftPM dependencies, and the
development container are available. API keys can be supplied to the smoke
executable through the matching environment variable; it adds the key only to
the child process's in-memory `env-secret.*` settings and never prints it:

```sh
make acp-live-smoke ACP_LIVE_AGENT=opencode
make acp-live-smoke ACP_LIVE_AGENT=codex
make acp-live-smoke ACP_LIVE_AGENT=claude-agent
```

When running inside the development container, pass the desired key only in
that invocation, for example `CODEX_API_KEY="$CODEX_API_KEY" make
acp-live-smoke ACP_LIVE_AGENT=codex`. Outside the container, install the agent
commands and authenticate in the same environment used by the smoke command.

Run one command at a time. The smoke executable creates a unique temporary
working directory, asks the agent to create and read one file there, reports
streamed tool/permission updates, and removes the directory on exit. It prompts
for approval when the agent requests permission; review each request before
approving. The executable uses the agent's existing login in its normal home;
it does not copy credentials. Authentication data and tool output are not
written into tracked fixtures. This target is explicitly opt-in and is not
referenced by `verify` or the CI workflow. Do not use it with sensitive prompts
or a directory containing production data.

Capture the agent and adapter versions, whether a permission request appeared,
how the file tool ran, and a redacted transcript on the owning issue. Remove
personal data, file paths, tokens, and other secrets from the transcript before
posting it. If a run cannot be completed, record the environmental blocker and
the exact replacement condition instead.

## Extending the bundled Positronic backend

The bundled Positronic backend accepts a static list of
`PositronicContribution` values at construction. A contribution is compiled in;
it is not loaded dynamically. It may expose additional tools and one bounded
`TurnContextSource`.

```swift
struct NotesContribution: PositronicContribution {
    let label = "notes"
    func turnContextSource() -> (any TurnContextSource)? { NotesContextSource() }
    func tools() -> [AnyTool] { [AnyTool(NotesTool())] }
}
```

A contribution cannot override a Workspace or network tool. Duplicate tool
identities or call names, and labels that collide with reserved tools, fail at
startup before the backend is published. A contribution label is static and
must not carry user payloads or secrets.

`TurnContextSource.failureRequirement` decides what a failure means: `.required`
aborts the Turn before provider work and leaves the backend healthy, while
`.optional` records a host notice and the Turn continues. The adapter scopes a
`PositronicTurnInvocation` to the Turn, so a source reads
`PositronicTurnInvocationContext.current` to correlate the Ascendant, Timeline,
and admitted client Turn it is projecting for.

### Selecting extensions per Ascendant

A composition root registers each compiled-in extension on `BackendComposition`,
keyed by a static name. The extension declares its own settings keys and builds
its contribution from the settings of the Ascendant that selected it:

```swift
var composition = BackendComposition()
composition.registerPositronicExtension(PositronicExtension(
    name: "notes",
    settingKeys: [
        .init(name: "topic", summary: "Notes topic."),
        .init(name: "token", summary: "Notes credential.", isSecret: true),
    ]
) { scope in
    NotesContribution(topic: try scope.stringSetting("topic"))
})
```

Each Ascendant opts in through the backend-owned `extensions` setting; existing
envelopes without the key behave exactly as before:

```json
{ "kind": "positronic", "settings": { "extensions": ["notes"], "notes.topic": "release" } }
```

Extension settings are namespaced `<name>.<key>` in `settings`. Secrets use the
same namespacing in `backend.secrets`, so they stay covered by the structural
redaction `gnostic config show` applies. The Positronic settings schema includes
the selection key and every registered extension key, so
`gnostic config backend keys <ascendant-id>` lists them.

Two Positronic Ascendants on one Node may select different sets. Selection is
static: there is no live enable, disable, or hot reload. An unknown or malformed
selection fails startup before advertisement and names the extension. The
rejected alternative, a distinct backend kind per variant, would multiply kinds
combinatorially and conflict with the single `positronic` kind the adapter
validates.

## What stays Gnostic's

Do not reimplement these. Gnostic remains authoritative for Ascendant and
Timeline identity, Workspace attachment intent, Turn admission and
serialization, idempotency and replay, permission correlation, and
advertisement. Your backend sees a Timeline identifier and a message.

See also [ADR 0002 — Gnostic identity versus backend state](../Architecture/ADRs/0002-gnostic-identity-vs-backend-state.md),
[ADR 0005 — Core PositronicKit dependency boundary](../Architecture/ADRs/0005-core-positronic-dependency-boundary.md),
and [ADR 0010 — Letta as the first non-Positronic Ascendant backend](../Architecture/ADRs/0010-letta-ascendant-backend-evaluation.md).
ADR 0010 records a fixture-backed, optional prototype that implements this
contract outside `GnosticCore`.
