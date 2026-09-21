// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Runs `operation` with the calling task's cancellation suppressed, on every
/// platform this package declares.
///
/// The standard library's cancellation-shield primitive is annotated
/// `@available(anyAppleOS 27.0, *)`, but it is also `@_alwaysEmitIntoClient`.
/// Its body is emitted into every module that references it, together with the
/// calls that body makes to the 27-only concurrency runtime entry points. Those
/// entry points become strong undefined symbols that the loader resolves when
/// the module loads, before any runtime availability branch can run, so a build
/// that targets the 26 line fails to load even though the branch is unreachable.
/// A runtime availability check cannot un-emit an always-emitted body, so this
/// wrapper never references the primitive: it always runs `operation` in an
/// unstructured task.
///
/// `operation` runs in the caller's isolation. The unstructured task is not a
/// child of the caller, so the body is shielded from the caller's cancellation.
package func withCancellationShield<Value: Sendable>(
    isolation: isolated (any Actor)? = #isolation,
    operation: nonisolated(nonsending) () async -> Value
) async -> Value {
    await withUnstructuredCancellationShield(isolation: isolation, operation: operation)
}

/// The cancellation shield used at every OS line.
///
/// An unstructured task is not a child of the caller, so it does not inherit
/// cancellation and runs `operation` to completion even when the caller is
/// already cancelled. Awaiting a non-throwing task's value is itself immune to
/// cancellation, so the shielded body always finishes before this function
/// returns.
func withUnstructuredCancellationShield<Value: Sendable>(
    isolation: isolated (any Actor)? = #isolation,
    operation: nonisolated(nonsending) () async -> Value
) async -> Value {
    await withoutActuallyEscaping(operation) { body in
        let shielded = ShieldedBody(body: body, callerActor: isolation)
        let task = Task { await shielded.run() }
        return await task.value
    }
}

/// Carries a caller-isolated body into the unstructured shield task together
/// with the actor it must run on.
private struct ShieldedBody<Value: Sendable>: @unchecked Sendable { // SAFETY: the body is only ever invoked after `invoke` hops back onto `callerActor`, and the caller stays suspended on `task.value` until it completes, so the caller-isolated captures are never touched concurrently.
    let body: nonisolated(nonsending) () async -> Value
    let callerActor: (any Actor)?

    func run() async -> Value {
        await invoke(isolation: callerActor)
    }

    /// The `isolated` parameter is what performs the hop; the body is
    /// `nonisolated(nonsending)`, so it then runs in that same isolation.
    private func invoke(isolation: isolated (any Actor)?) async -> Value {
        await body()
    }
}
