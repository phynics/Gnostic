# ADR 0005 — Core PositronicKit dependency boundary

## Status

Superseded for the Core dependency boundary by the GNO-PLAT-P7 Positronic
backend extraction below. The historical investigation and the ACP
re-evaluation remain for context; the current invariant is that `GnosticCore`
carries no Positronic dependency and every native conversion lives in
`GnosticPositronicBackend`.

## Context

`GnosticCore` is an Axoloty-native host and currently bundles the built-in
Positronic Backend. An import count therefore cannot distinguish a legitimate
host bridge from a PositronicKit type that has escaped into a Gnostic-owned
contract. The earlier Workspace boundary work removed native Workspace values
from network projections, but did not inventory the complete Core target.

## Original decision

Keep the direct PositronicKit dependency on `GnosticCore` for the bundled
Positronic Backend and the explicit host bridges that materialize, project, or
invoke PositronicKit Workspaces. Do not split a downstream Positronic target in
that increment: the runtime composition root, bundled backend, and host bridge
shared one release and there was no second backend or measured build/ownership
benefit that justified a package boundary then.

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
`Adapters/FileTimelineRuntimeRepository.swift`,
`Adapters/PositronicAscendantAdapter.swift`,
`Adapters/PositronicContribution.swift`,
`Adapters/WorkspaceProvider.swift`,
`Providers/AscendantTurnProvider.swift`,
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
| `Adapters/PositronicAscendantAdapter.swift` | Positronic Backend implementation | Owns native Agent/TimelineRecord construction, persistence, tools, events, and shutdown. Native values do not cross `AscendantBackend`. |
| `Adapters/FileTimelineRuntimeRepository.swift` | Durable Timeline runtime store | Composes the in-memory reference repository with Gnostic's append-only event log to persist Timeline history and Turn transitions across restarts. The `BackendTimelineStoreCapability` it defines carries only the backend-neutral `TimelineRuntimeRepository`/`WorkspaceBindingRepository` existentials. |
| `Adapters/PositronicContribution.swift` | Positronic contribution seam | Generic, statically selected extension of one Positronic Ascendant: additional tools and one bounded `TurnContextSource`. Native tool/context values stay inside the bundled backend boundary; the seam carries no experiment type. |
| `Adapters/AxolotyWorkspace.swift`, `Runtime/WorkspaceService.swift`, `Runtime/BackendWorkspaceService.swift` | Explicit Workspace host bridge | Converts Gnostic-owned references and backend capability values to native Workspace values only at the local execution seam. |
| `Services/WorkspaceReferenceProjection.swift` | Explicit projection adapter | Performs the only generic Workspace-reference conversion in both directions. |
| `Services/DiscoveredWorkspaceAttachmentService.swift` | Positronic attachment bridge | Uses native Timeline/Workspace capabilities behind the backend-owned attachment tool path. |
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

## Re-evaluation after ACP backend delivery

This section records the pre-extraction re-evaluation. The GNO-PLAT-P7
extraction below supersedes its outcome; the Core PositronicKit inventory it
describes no longer exists.

The trigger to re-evaluate this decision has occurred: `GnosticACPAscendant`
ships the supported `acp-client` backend kind outside `GnosticCore`. The current
Core PositronicKit source-import inventory remains the 15-file PositronicKit
subset of the inventory above (the fitness test's `expectedImports` set). The
test compares that exact set with the imports found under `Sources/GnosticCore`
and requires every listed path to appear in this inventory. The Core target
retains its PositronicKit dependency.

The ACP target does not import or call the Positronic adapter, and no code is
shared between `GnosticACPAscendant` and `PositronicAscendantAdapter`. The ACP
kind is selected through the flat `AscendantBackend` contract and is registered
outside Core. Its delivery adds no ACP, process, or SDK dependency to Core and
does not change the PositronicKit inventory.

**Decision: keep the Positronic adapter bundled in `GnosticCore`.** Shipping a
second backend kind proves that multiple backends can coexist behind the flat
contract, but this ACP backend supplies no evidence that splitting the existing
adapter would reduce Core build cost or establish a useful independent
ownership/release boundary. The extraction trigger is therefore satisfied as a
re-evaluation condition, not as an automatic extraction rule.

### Invariant

Gnostic-owned contracts remain free of native PositronicKit values. Native
PositronicKit usage remains confined to the explicit backend and host bridge
inventory above. Other backend targets continue to implement the flat
`AscendantBackend` contract without depending on the Positronic adapter.

### Rejected alternative

Extracting the Positronic adapter now is rejected. The ACP target neither shares
its code nor creates a Core dependency that extraction would remove; an
additional package boundary would add composition and maintenance cost without
a demonstrated build or ownership benefit.

### Dependency impact

No dependency, package manifest, or target dependency changes result from this
re-evaluation. `GnosticCore` retains its existing PositronicKit dependency and
the ACP target remains outside Core with no Positronic adapter dependency.

### Fitness check

`BackendArchitectureFitnessTests.corePositronicDependencyBoundaryIsExplicit`
compares the Core PositronicKit imports with the exact 15-path set and checks
that the ADR documents each path. `make verify` runs this check. It will fail
when a Core import is added or removed without an explicit inventory review.
ADR 0011's ACP boundary fitness checks continue to ensure Core has no ACP SDK
or process dependency and that the ACP target uses the flat backend contract.

### Reconsideration condition

Reconsider extraction when measurements show a material Core build benefit, or
when the Positronic adapter needs an independent release or ownership boundary.
A later backend shipping on its own is not sufficient by itself; the review
must identify a concrete dependency, build, or ownership benefit and update
this decision before extracting.

## GNO-PLAT-P7 wire contract extraction

Epic [#460](https://github.com/phynics/Gnostic/issues/460) splits the
backend-neutral wire and projection contracts out of `GnosticCore` into a new
`GnosticProtocol` library target. The first increment delivers that target and
records the boundary:

- `GnosticProtocol` holds the Axoloty wire contract (`GnosticProtocol`,
  `GnosticWirePayload`), the backend-neutral Ascendant contract
  (`AscendantInteroperabilityCapability`, `AscendantBackendHealth`,
  `AscendantBackendCapabilities`, `AscendantBackendIdentity`,
  `AscendantBackendTimeline`), the object projections
  (`GnosticAscendantObject`, `GnosticTimelineObject`,
  `GnosticWorkspaceObject`, `GnosticWorkspaceToolObject`,
  `GnosticWorkspaceTypes`), the network catalog value types
  (`NetworkCatalogStructures`), `AscendantTurnError`, `ManifestJSONValue`, and
  the Axoloty 0.7 compatibility object-model base (`CoreType`, `CoatyUUID`,
  `CoatyObject`) that those projections inherit.
- The target depends only on `Axoloty` and `AxolotyWire`. It does not import or
  depend on `GnosticCore`, `GnosticHost`, `GnosticKit`, `PositronicKit`,
  `PKContracts`, `PKPrompt`, or `ACP`.
- `GnosticCore` depends on `GnosticProtocol` and re-exports it with
  `@_exported import GnosticProtocol`, so an existing `import GnosticCore`
  consumer keeps the same source surface and needs no source change.

### Invariant

Backend-neutral contracts and projections live in `GnosticProtocol`; kernel
runtime, transport manager, and PositronicKit bridge code stay in
`GnosticCore`. PositronicKit remains a `GnosticCore` dependency and does not
reach `GnosticProtocol`.

### Rejected alternative

Moving the consumer clients (`GnosticTurnClient`, `GnosticWorkspaceClient`,
`GnosticSubscription`, `NetworkCatalog`) into a `GnosticClient` target in the
same increment is rejected. Those types use the internal runtime effect types
(`RuntimeEffectScope`, `RuntimeEffectHandle`), so extraction first needs a
decision about where the shared subscription and effect machinery lives. That
decision is deferred to a later increment rather than forcing a new shared
service layer in this one.

### Dependency impact

`Package.swift` adds a `GnosticProtocol` library product and target, and
`GnosticCore` gains a `GnosticProtocol` dependency. No third-party dependency
changes. `GNO-EXC-0001` in `Documentation/Architecture/exceptions.json` now
names both the object-model base file in `GnosticProtocol` and the transport
shim in `GnosticCore`.

### Fitness check

`BackendArchitectureFitnessTests.protocolTargetHasNoKernelDependencies` scans
`Sources/GnosticProtocol` for kernel and host imports, checks the
`GnosticProtocol` target block in `Package.swift`, and checks that
`GnosticCore` declares the `GnosticProtocol` dependency. `make verify` runs it.

### Reconsideration condition

Satisfied by the consumer SDK extraction below: the kernel is the accepted
owner of the shared catalog and subscription machinery, and it keeps the
runtime effect types internal.

## GNO-PLAT-P7 consumer SDK extraction

Epic [#460](https://github.com/phynics/Gnostic/issues/460) moves the
consumer-facing session and typed clients out of `GnosticCore` into a new
`GnosticClient` library target. The increment resolves the P7-002 blocker: the
kernel is the accepted owner of the shared catalog and subscription machinery,
so the effect types stay internal and the SDK uses only public kernel API.

- `GnosticClient` holds `GnosticConsumerSession`, the typed
  `GnosticTurnClient`, `GnosticTimelineClient`, `GnosticWorkspaceClient`, and
  `GnosticDiagnosticsClient`, their public errors, and the internal
  call-channel and provider-resolution support they share.
- The target depends on `GnosticProtocol` and `GnosticCore`, plus Axoloty. It
  declares no PositronicKit, `PKContracts`, backend, `GnosticHost`,
  `GnosticKit`, `GnosticCLI`, Atlas, or module dependency, and its sources
  import no Positronic backend.
- `GnosticCore` keeps `CommunicationManager`, `GnosticSubscription`,
  `NetworkCatalog`, `GnosticRawWireEvent`, `RuntimeEffectScope`, and
  `RuntimeEffectHandle`. The kernel runtime, `WorkspaceDiscovery`, and
  `GnosticWorkspaceProvider` continue to use the shared machinery, so it
  cannot move above the kernel.

### Invariant

The consumer SDK sits above the kernel and the kernel never reaches back into
it. `GnosticCore` must not depend on or import `GnosticClient`. The SDK's
declared dependencies and sources carry no PositronicKit, `PKContracts`, or
backend value.

### Rejected alternative

Moving `GnosticSubscription` and `NetworkCatalog` into `GnosticClient`, or
introducing a new shared transport target below the kernel, is rejected in this
increment. The kernel runtime (`NodeAssembly`, `WorkspaceDiscovery`,
`GnosticWorkspaceProvider`) consumes both types, so moving them up would force
`GnosticCore` to depend on `GnosticClient` and invert the boundary. A new lower
target would move `CommunicationManager` and the Axoloty provider-registration
shim out of the kernel, which is a P7-004-scale change with no measured benefit
in this increment.

### Dependency impact

`Package.swift` adds a `GnosticClient` library product and target, and adds the
target to the consumers that already used the facade (`GnosticACPFrontend`,
`GnosticCLI`, `GnosticSoakDriver`, and the core test target). No third-party
dependency changes. Consumers that reached the facade through
`import GnosticCore` now add `import GnosticClient`;
`Documentation/Compatibility/0.5.0.md` records the migration.

### Fitness check

`GnosticClientTests.ClientArchitectureFitnessTests` pins the move: the consumer
files live in `Sources/GnosticClient` and not in `Sources/GnosticCore/Services`,
the `GnosticClient` target declares no backend dependency and its sources
import no PositronicKit or `PKContracts`, and `GnosticCore` neither depends on
nor imports `GnosticClient`.
`GnosticCLITests.CompositionArchitectureFitnessTests.layerDependencies` adds
the same kernel-direction check. `make verify` runs them.

### Reconsideration condition

Reconsider when P7-004 removes PositronicKit from `GnosticCore`; at that point
the SDK no longer links PositronicKit transitively through the kernel, and a
future increment can decide whether a dedicated lower transport target is
warranted.

## GNO-PLAT-P7 Positronic backend extraction

Epic [#460](https://github.com/phynics/Gnostic/issues/460) extracts the bundled
Positronic backend out of `GnosticCore` into a new
`GnosticPositronicBackend` library target. The kernel keeps a neutral backend
contract and no PositronicKit dependency.

- `GnosticPositronicBackend` holds the bundled
  `PositronicAscendantAdapter`, `PositronicContribution` and its runtime
  context, `AxolotyWorkspace`, `FileTimelineRuntimeRepository`,
  `DiscoveredWorkspaceAttachmentService`, `NetworkManagementTools`,
  `AscendantToolApprovalPolicy`, the deterministic `EchoWorkspace`, the
  `PositronicBackend.register(into:)` composition seam, and
  `PositronicWorkspaceProjection`. Every PositronicKit and `PKContracts`
  conversion lives there.
- The target depends on `GnosticCore`, `GnosticProtocol`, Axoloty,
  `PositronicKit`, and `PKContracts`. `GnosticHost`, `GnosticPositronicAtlas`,
  `GnosticPositronicContext`, the runner, and the CLI test targets depend on it.
- `GnosticCore` depends only on `GnosticProtocol`, Axoloty, `AxolotyMQTT`, and
  `Logging`. It imports no PositronicKit, `PKContracts`, or `PKPrompt`, and its
  target block names none of them.
- The kernel keeps the neutral contracts: `AscendantBackend`, the
  `BackendWorkspace*` values, `LocalWorkspace`, `LocalWorkspaceFileAccess`,
  `LocalWorkspaceHealth`, `NetworkWorkspaceInvoking`, `WorkspaceDiscovery`,
  `MultiplexedWorkspaceProvider`, `WorkspaceService`,
  `BackendWorkspaceService`, and `WorkspaceReferenceProjection`. A composition
  root installs the bundled backend with `PositronicBackend.register(into:)`
  and `registerPositronicBackend(languageModel:)`.

### Invariant

`GnosticCore` is Positronic-free: it declares no PositronicKit, `PKContracts`,
or `PKPrompt` dependency and no source under `Sources/GnosticCore` imports one.
All provider conversion sits behind the `GnosticPositronicBackend` target. The
kernel reaches the bundled implementation only through neutral protocols and
adapter registries.

### Rejected alternative

Keeping the adapter in `GnosticCore` with the previous import inventory is
rejected. The measured outcome of the split is a kernel target that builds
without linking PositronicKit and a backend target that owns every native
value, so a new import in Core now fails the fitness check instead of requiring
an inventory review.

### Dependency impact

`Package.swift` adds a `GnosticPositronicBackend` library product and target,
removes `PositronicKit` and `PKContracts` from `GnosticCore`, and adds the new
target to `GnosticHost`, `GnosticPositronicAtlas`, `GnosticPositronicContext`,
the runner executables, and the affected test targets. No third-party
dependency version changes. `Documentation/Compatibility/0.5.0.md` records the
source migration for consumers that imported a moved type from `GnosticCore`.

### Fitness check

`BackendArchitectureFitnessTests.corePositronicDependencyBoundaryIsExplicit`
asserts that no `Sources/GnosticCore` file imports PositronicKit,
`PKContracts`, or `PKPrompt`, that the `GnosticCore` target block names none of
them, and that the `GnosticPositronicBackend` target declares `GnosticCore`,
PositronicKit, and `PKContracts`. `make verify` runs it. The earlier Core
PositronicKit-import inventory is superseded; this ADR remains the boundary
record and no longer lists Core Positronic seams.

### Reconsideration condition

Reconsider when a second backend needs the same native conversion, or when the
backend target must release independently of the kernel. A new PositronicKit
import in `GnosticCore` requires a new decision and an architecture exception
before the fitness check may pass again.

## Rejected alternatives

- Removing PositronicKit from Core would remove the bundled Positronic Backend,
  not enforce a boundary.
- At the time of the original decision, splitting packages without a second
  backend or measured build/ownership gain would have added composition
  complexity without changing ownership.
- Replacing Axoloty or abstracting all transport would violate ADR 0001.
- Treating an import count as proof of a leak would incorrectly classify the
  explicit backend and host adapters.

## Reconsideration triggers

Reconsider extraction into a downstream Positronic target when the Positronic
adapter needs an independent release/ownership boundary or build measurements
show a material Core build benefit. A second backend shipping prompts explicit
review but does not alone require extraction; the ACP delivery re-evaluation
above records this outcome. Reconsider the `PKContracts` host seam if Axoloty or
the backend capability protocols offer a stable Gnostic-owned replacement
without widening transport abstraction.

## Links

- [ADR 0001 — Axoloty-native multi-backend host](0001-axoloty-native-multi-backend-host.md)
- [ADR 0002 — Gnostic identity versus backend state](0002-gnostic-identity-vs-backend-state.md)
- [GNO-RESET-004 #138](https://github.com/phynics/Gnostic/issues/138)
- [GNO-RESET-FOLLOWUP-001 #162](https://github.com/phynics/Gnostic/issues/162)
- [GNO-RESET-FOLLOWUP-006 #167](https://github.com/phynics/Gnostic/issues/167)
