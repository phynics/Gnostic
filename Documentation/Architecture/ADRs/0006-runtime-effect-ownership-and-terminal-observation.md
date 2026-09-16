# ADR 0006 — Runtime effect ownership and terminal observation

Runtime effects are structurally owned by `RuntimeEffectScope`. A scope is an
ownership and cleanup boundary; it is not a dependency-injection container,
service locator, configuration store, dynamic loader, or domain authority.

Terminal Turn observation is a one-way, backend-neutral Core seam. Hosts install
`TerminalTurnObserving` values through `NodeRuntimeAdapters`. A
`TerminalTurnRecord` contains only Gnostic identity and the bounded
`TerminalTurnOutcome`; Atlas, Shard, prompt, revision, and PositronicKit types
remain outside the contract. Exact shutdown waits for Turn and lane settlement
before closing the observation fence, then drains admitted observer deliveries
up to `observationDrainTimeout`; a stuck observer is cut off at the bound. Every
observer receives at most one delivery per original identified terminal Turn,
and only if it was admitted before the fence. Bounded shutdown (the production
path) cancels Turn and lane tasks and then waits up to `observationDrainTimeout`
for them to settle, so a Turn that honours cancellation is still observed. Only
work that outlives that window is cut off: its terminal outcome remains
identified/replay-backed domain state (or is discarded for the unobserved
compatibility path), but does not start observer work after the lifecycle
boundary.

The design rejects Atlas-aware Core, Core-side Shard report generation, mutable
post-start observer registries, and dynamic plugin observers. These alternatives
would reverse dependency direction, make lifecycle ownership implicit, or add
configuration and loading authority to a cleanup primitive.

`RuntimeOwnershipArchitectureFitnessTests.scopeHasNoForbiddenAuthority` pins
the scope's forbidden dependencies, `.scopeOwnersArePinned` pins every owner
and name, `.observationContractHasNoAtlasVocabulary` protects the generic
observation boundary, and `.identitySnapshotHasNoEffectState` keeps diagnostics
out of domain projections. `RuntimeEffectScopeTests.labelsRejectDynamicOrUnsafeDiagnosticContent`
protects label safety. Runtime integration tests prove that the default empty
observer list preserves existing behavior and that installed observers receive
terminal outcomes through the NodeRuntime seam. Scope-adoption tests enforce one
live parent per child, and subscription lifecycle tests enforce a single
actor-safe start/stop owner.

This decision adds no production dependency. Once #116 lands, the optional
`GnosticPositronicAtlas` target will consume the generic Core seam and own
correlation, provenance, origin suppression, and revision snapshots.

This ADR is the accepted repository ADR 0006. The historical
`0006-timeline-bound-backend-execution.md` on
`codex/timeline-bound-backend-sessions` is not an alternative current ADR; ADR
0007 records its archive disposition.
