// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticRLM

/// Deterministic corpus fixtures shared by the RLM harness suites.
enum RLMFixtures {
    static let retirementSource = """
    // Backend retirement supervision.

    struct BackendRetirementSupervisor {
        // A retirement begins by invalidating the backend lease so no new
        // generation can be admitted against the retiring backend.
        func beginRetirement(generation: UInt64) {
            invalidateLease()
            fenceGeneration(generation)
        }

        // Stale completions are rejected when their generation does not match
        // the current runtime generation.
        func acceptCompletion(generation: UInt64) -> Bool {
            generation == currentGeneration
        }

        func invalidateLease() {}
        func fenceGeneration(_ generation: UInt64) {}
        var currentGeneration: UInt64 { 0 }
    }
    """

    static let ascendantSource = """
    // Ascendant backend supervision.

    final class AscendantBackendSupervisor {
        // The supervisor retires a backend after the last Turn settles and
        // rejects any stale generation that arrives during retirement.
        func retireAfterTurn(lease: Lease, generation: UInt64) {
            lease.invalidate()
            pendingRetirement = generation
        }

        // A completion older than the retirement generation is fenced.
        func leaseAllows(generation: UInt64) -> Bool {
            generation >= pendingRetirement
        }

        var pendingRetirement: UInt64 = 0
    }

    struct Lease {
        func invalidate() {}
    }
    """

    static let runtimeSource = """
    // Node runtime generation fencing.

    // The runtime advances a generation whenever a backend is replaced. A
    // stale completion from an older generation cannot retire or resurrect a
    // live backend.
    func fenceStaleCompletion(runGeneration: UInt64, currentGeneration: UInt64) -> Bool {
        runGeneration == currentGeneration
    }

    // Retirement is bounded: the supervisor waits for the lease grace period,
    // then terminates the backend.
    func boundedRetirementDeadline(lease: Lease) -> Duration {
        lease.gracePeriod
    }

    extension Lease {
        var gracePeriod: Duration { .seconds(5) }
    }
    """

    static let lifecycleSource = """
    // Runtime lifecycle coordination for retirement.

    struct RuntimeLifecycleCoordinator {
        // The coordinator owns the retirement lease and the generation fence.
        // It refuses to admit work against a retired or retiring backend.
        func admit(generation: UInt64) -> Bool {
            !retiring && generation == activeGeneration
        }

        // Cancellation fences late work by advancing the generation.
        mutating func cancel() {
            retiring = true
            activeGeneration += 1
        }

        var retiring = false
        var activeGeneration: UInt64 = 1
    }
    """

    static let documentationSource = """
    # Backend retirement

    Retirement invalidates the backend lease, advances the runtime generation,
    and fences stale completions. The retirement path is bounded and leaves no
    live generation behind.
    """

    static let readmeSource = """
    # Gnostic

    Gnostic hosts Ascendant backends. See the retirement and generation
    documentation for lifecycle details.
    """

    static let binaryBytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x00, 0x1A, 0x0A]
    static let invalidUTF8Bytes: [UInt8] = [0x41, 0x42, 0xC3, 0x28, 0x43]

    /// A small, deterministic repository-shaped corpus.
    static func repositorySource() -> RLMInMemoryCorpusSource {
        RLMInMemoryCorpusSource(
            files: [
                "Sources/GnosticCore/Runtime/BackendRetirementSupervisor.swift": Array(retirementSource.utf8),
                "Sources/GnosticCore/Runtime/AscendantBackendSupervisor.swift": Array(ascendantSource.utf8),
                "Sources/GnosticCore/Runtime/NodeRuntime.swift": Array(runtimeSource.utf8),
                "Sources/GnosticCore/Runtime/RuntimeLifecycleCoordinator.swift": Array(lifecycleSource.utf8),
                "Documentation/Architecture/retirement.md": Array(documentationSource.utf8),
                "README.md": Array(readmeSource.utf8),
                "Assets/diagram.png": binaryBytes,
                "Sources/legacy/Broken.swift": invalidUTF8Bytes,
            ]
        )
    }

    /// A source that lists only text files, for snapshot-focused tests.
    static func textSource() -> RLMInMemoryCorpusSource {
        RLMInMemoryCorpusSource(
            textFiles: [
                "Sources/A.swift": "let alpha = 1\nlet beta = 2\n",
                "Sources/B.swift": "let gamma = 3\nlet delta = 4\n",
                "Documentation/notes.md": "retirement lease generation\n",
            ]
        )
    }
}
