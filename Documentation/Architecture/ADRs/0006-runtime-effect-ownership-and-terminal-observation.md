# ADR 0006 — Runtime effect ownership and terminal observation

Runtime effects are structurally owned by `RuntimeEffectScope`. A scope is an
ownership and cleanup boundary; it is not a dependency-injection container,
service locator, configuration store, dynamic loader, or domain authority.

Terminal Turn observation is a one-way, backend-neutral Core seam. Hosts install
`TerminalTurnObserving` values through `NodeRuntimeAdapters`. A
`TerminalTurnRecord` contains only Gnostic identity and the bounded
`TerminalTurnOutcome`; Atlas, Shard, prompt, revision, and PositronicKit types
remain outside the contract.

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
terminal outcomes through the NodeRuntime seam.

This decision adds no production dependency. Once #116 lands, the optional
`GnosticPositronicAtlas` target will consume the generic Core seam and own
correlation, provenance, origin suppression, and revision snapshots.
