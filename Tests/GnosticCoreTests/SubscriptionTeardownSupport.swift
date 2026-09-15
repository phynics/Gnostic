// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import GnosticCore

extension GnosticSubscription {
    /// Test-only teardown for `defer`, which cannot await. Production code
    /// calls ``GnosticSubscription/stopAndWait()`` so that shutdown ordering
    /// stays structurally owned; this helper exists only so a failing test
    /// still releases its broker subscription.
    @MainActor
    func stopInTeardown() {
        Task { @MainActor in await self.stopAndWait() }
    }
}
