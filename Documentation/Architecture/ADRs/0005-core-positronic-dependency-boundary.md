# ADR 0005 — Core PositronicKit dependency boundary

## Status

Accepted investigation result. This decision is delivered with follow-up issue
[#167](https://github.com/phynics/Gnostic/issues/167).

## Context

`GnosticCore` is an Axoloty-native host and currently bundles the built-in
Positronic Backend. An import count therefore cannot distinguish a legitimate
host bridge from a PositronicKit type that has escaped into a Gnostic-owned
contract. The earlier Workspace boundary work removed native Workspace values
from network projections, but did not inventory the complete Core target.

## Decision

Keep the direct PositronicKit dependency on `GnosticCore` for the bundled
Positronic Backend and the explicit host bridges that materialize, project, or
invoke PositronicKit Workspaces. Do not split a downstream Positronic target in
this increment: the runtime composition root, bundled backend, and host bridge
share one release and there is no second backend or measured build/ownership
benefit that justifies a package boundary yet.

The Core-owned Workspace network contract uses `ManifestJSONValue`; it does not
expose PositronicKit's `AnyCodable` or native Workspace reference/status/tool
types. Conversion to and from PositronicKit remains in
`WorkspaceReferenceProjection` and the backend/host adapters.

`PKContracts` remains a host-boundary dependency where Axoloty Call handlers,
PositronicKit tools, permission mediation, and local Workspace execution
require its value/result protocols. Those APIs are adapter or transport seams,
not Gnostic identity, manifest, backend, or network projection types.

The retained `PKContracts` imports are limited to the explicit adapter and
transport seams in `Adapters/AxolotyWorkspace.swift`,
`Adapters/PositronicAscendantAdapter.swift`,
`Adapters/WorkspaceProvider.swift`,
`Providers/AgentChatProvider.swift`,
`Providers/TimelineManagementProvider.swift`,
`Providers/TimelineStatusProvider.swift`,
`Providers/WorkspaceOpsProvider.swift`,
`Runtime/AscendantPermissionCoordinator.swift`,
`Runtime/BackendWorkspaceService.swift`,
`Runtime/MultiplexedWorkspaceProvider.swift`,
`Runtime/NodeAssembly.swift`,
`Runtime/NodeRuntime.swift`,
`Runtime/NodeRuntimeAdapters.swift`,
`Runtime/NodeRuntimeHost.swift`,
`Runtime/NodeTransport.swift`,
`Runtime/WorkspaceService.swift`,
`Services/DiscoveredWorkspaceAttachmentService.swift`,
`Services/NetworkManagementTools.swift`, and
`Services/WorkspaceReferenceProjection.swift`. The architecture fitness test
compares this set mechanically so a new import requires an explicit boundary
review.

## Import inventory

Every remaining `PositronicKit` import in `GnosticCore` has one of these roles:

| Files | Role | Boundary rule |
| --- | --- | --- |
| `Adapters/PositronicAscendantAdapter.swift` | Positronic Backend implementation | Owns native Agent/Thread construction, persistence, tools, events, and shutdown. Native values do not cross `AscendantBackend`. |
| `Adapters/AxolotyWorkspace.swift`, `Runtime/WorkspaceService.swift`, `Runtime/BackendWorkspaceService.swift` | Explicit Workspace host bridge | Converts Gnostic-owned references and backend capability values to native Workspace values only at the local execution seam. |
| `Services/WorkspaceReferenceProjection.swift` | Explicit projection adapter | Performs the only generic Workspace-reference conversion in both directions. |
| `Services/DiscoveredWorkspaceAttachmentService.swift` | Positronic attachment bridge | Uses native Thread/Workspace capabilities behind the backend-owned attachment tool path. |
| `Services/NetworkManagementTools.swift` | Positronic tool implementation | Implements backend-private network inspection and attachment tools. |
| `Adapters/WorkspaceProvider.swift` | Positronic workspace call bridge | Adapts Axoloty workspace calls to PositronicKit Workspace errors and tool results. |
| `Runtime/NodeRuntimeAdapters.swift` | Composition registry | Registers the bundled Positronic factory and local Workspace adapters; generic backends use `registerBackend`. |
| `Runtime/NodeAssembly.swift`, `Runtime/NodeRuntime.swift`, `Runtime/NodeRuntimeHost.swift`, `Runtime/NodeTransport.swift`, `Runtime/MultiplexedWorkspaceProvider.swift` | Host composition and transport | Keeps native Workspace/tool values in runtime-local forwarding and registration code. |

Redundant imports in generic lifecycle, projection, and provider files were
removed. `PKPrompt` had no Core source consumer and is no longer a Core or Core
test target dependency.

## Public boundary invariant

Gnostic-owned manifest, identity, backend, and network Workspace types must use
Foundation or Gnostic-owned values. PositronicKit native types may appear only
inside the inventory above or in the optional `GnosticPositronicAtlas` target.
Architecture fitness tests fail if native Workspace values or `AnyCodable`
re-enter the Core-owned Workspace projection types.

## Rejected alternatives

- Removing PositronicKit from Core would remove the bundled Positronic Backend,
  not enforce a boundary.
- Splitting packages without a second backend or measured build/ownership gain
  would add composition complexity without changing ownership.
- Replacing Axoloty or abstracting all transport would violate ADR 0001.
- Treating an import count as proof of a leak would incorrectly classify the
  explicit backend and host adapters.

## Reconsideration triggers

Reconsider extraction into a downstream Positronic target when a second backend
is shipped, the Positronic adapter needs an independent release/ownership
boundary, or build measurements show a material Core build benefit. Reconsider
the `PKContracts` host seam if Axoloty or the backend capability protocols offer
a stable Gnostic-owned replacement without widening transport abstraction.

## Links

- [ADR 0001 — Axoloty-native multi-backend host](0001-axoloty-native-multi-backend-host.md)
- [ADR 0002 — Gnostic identity versus backend state](0002-gnostic-identity-vs-backend-state.md)
- [GNO-RESET-004 #138](https://github.com/phynics/Gnostic/issues/138)
- [GNO-RESET-FOLLOWUP-001 #162](https://github.com/phynics/Gnostic/issues/162)
- [GNO-RESET-FOLLOWUP-006 #167](https://github.com/phynics/Gnostic/issues/167)
