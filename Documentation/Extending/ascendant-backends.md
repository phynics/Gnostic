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
registered solely inside a running host can be built but not configured
through the CLI.

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

See also [ADR 0002 — Gnostic identity versus backend state](../Architecture/ADRs/0002-gnostic-identity-vs-backend-state.md)
and [ADR 0005 — Core PositronicKit dependency boundary](../Architecture/ADRs/0005-core-positronic-dependency-boundary.md).
