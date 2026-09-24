# Implementing a Workspace adapter

A Workspace is a named set of capabilities a Timeline can attach. Gnostic owns
attachment intent and advertisement; the adapter owns the tools and executes
them.

## Choose the protocols you actually satisfy

`WorkspaceProvider` is the base. Add only what your adapter really does:

- `WorkspaceToolProvider` — `listTools()` and `executeTool(id:parameters:)`.
  This is what a remote caller reaches through
  `me.atkn.gnostic.workspace.invoke`.
- `WorkspaceFileProvider` — `readFile`, `writeFile`, `listFiles`,
  `deleteFile`. Implement it only for an adapter that is genuinely a
  filesystem. Direct file APIs are not exposed to attached network Workspaces.

Advertise only tools you can execute. `NodeAssembly` derives the advertised
`WorkspaceReference` from `listTools()`, so a tool you list is a tool a client
may call.

## Registering

```swift
var adapters = NodeRuntimeAdapters.default
adapters.workspaces.registerProduct(kind: "ledger") { configuration in
    LedgerWorkspace(configuration: configuration)
}
```

`registerProduct(kind:factory:)` is the registration seam. The adapter owns its
own `WorkspaceReference` — its identifier, URI, and tool projection — and
Gnostic does not invent any of it.

`WorkspaceAdapterRegistry.registeredKinds` enumerates what a registry can
build.

## Why the adapter owns its reference

An earlier seam, `register(kind:factory:)`, handed the factory a runtime-built
`WorkspaceReference` to adopt. The runtime cannot know an adapter's tools, so
an adapter that projected the reference it was handed advertised whatever the
runtime guessed, and at one point every such adapter advertised the bundled
echo tool and then rejected the call. That seam was removed after 0.4.

## Local and network Workspaces

A locally configured Workspace is materialised at startup from the manifest. A
network Workspace is discovered, and is imported only when exactly one
available, well-formed provider advertises it; ambiguous, malformed, or
deadvertised advertisements cannot be attached. Attachment requires user
approval and routes through Gnostic's authoritative Workspace service.

Attached Workspaces expose only their advertised custom tool definitions.

See also
[ADR 0001 — Axoloty-native multi-backend host](../Architecture/ADRs/0001-axoloty-native-multi-backend-host.md).
