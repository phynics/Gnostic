// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Runs `operation` with the calling task's cancellation suppressed, on every
/// platform this package declares.
///
/// The standard library's `withTaskCancellationShield` is annotated
/// `@available(anyAppleOS 27.0, *)`, while this package's manifest supports the
/// 26 line. Calling it directly still compiles on Linux, where the availability
/// clause is vacuous, but fails to build for a 26 deployment target. Shutdown
/// and cleanup paths need the shield on every supported platform, so they call
/// this wrapper instead of the shielded primitive.
///
/// `operation` runs in the caller's isolation on both paths: the standard
/// library entry point is `nonisolated(nonsending)`, and the fallback hops back
/// onto the caller's actor before it invokes the body.
package func withCancellationShield<Value: Sendable>(
    isolation: isolated (any Actor)? = #isolation,
    operation: nonisolated(nonsending) () async -> Value
) async -> Value {
    if #available(anyAppleOS 27.0, *) {
        return await withTaskCancellationShield(operation: operation)
    }
    return await withUnstructuredCancellationShield(isolation: isolation, operation: operation)
}

/// The pre-27 shield. An unstructured task is not a child of the caller, so it
/// does not inherit cancellation and runs `operation` to completion even when
/// the caller is already cancelled. Awaiting a non-throwing task's value is
/// itself immune to cancellation, so the shielded body always finishes before
/// this function returns.
///
/// Only reachable at runtime below the 27 OS line, so it is validated through
/// its own tests rather than through `withCancellationShield`.
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
