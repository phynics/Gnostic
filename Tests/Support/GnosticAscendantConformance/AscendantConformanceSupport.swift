// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore

/// The outcome the conformance suite asks one fixture Turn to produce.
public enum AscendantConformanceOutcome: Sendable, Equatable {
    /// The Turn completes with the fixture's reply for the message.
    case reply(String)
    /// The Turn fails with ``AscendantBackendError/terminal(_:)``.
    case terminalFailure
    /// The Turn never completes until the backend cancels it.
    case stall
}

/// Optional contract surfaces. A kind that does not implement one is recorded
/// as an explicit, issue-owned exception in GNO-PLAT-060 (#452) rather than
/// asserted here.
public struct AscendantConformanceSurfaces: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Implements ``AscendantBackendTurnCancellation``.
    public static let scopedCancellation = Self(rawValue: 1 << 0)
    /// Implements ``AscendantBackendWorkspaceCapability``.
    public static let workspaceAttachment = Self(rawValue: 1 << 1)
    /// Marks the final streamed update terminal.
    public static let terminalUpdate = Self(rawValue: 1 << 2)
}

/// The message markers every fixture recognizes.
///
/// The literals are the ACP fixture agent's existing tokens. The Letta and
/// Positronic fixtures recognize the same tokens so one suite drives every
/// kind without changing the ACP fixture.
public enum AscendantConformanceMessage {
    /// A message whose Turn completes with the fixture's reply.
    public static func reply(_ text: String) -> String { text }
    /// A message whose Turn fails with ``AscendantBackendError/terminal(_:)``.
    public static let terminalFailure = "[fixture:terminal-error]"
    /// A message whose Turn stalls until the backend cancels it.
    public static let stall = "[fixture:wait]"

    /// The message the suite sends for one scenario.
    public static func message(for outcome: AscendantConformanceOutcome) -> String {
        switch outcome {
        case let .reply(text): text
        case .terminalFailure: terminalFailure
        case .stall: stall
        }
    }
}

/// The reply text a cooperating fixture returns for a plain message.
public enum AscendantConformanceReply {
    /// Prefix every fixture reply carries, so the suite can recognize its Turn.
    public static let prefix = "conformance reply:"

    /// The reply for one plain message.
    public static func make(for message: String) -> String { "\(prefix) \(message)" }
}

/// Every conformance check that failed, reported in one error so a single run
/// lists every divergence instead of stopping at the first.
public struct AscendantConformanceFailure: Error, CustomStringConvertible {
    /// The backend kind under test.
    public let kind: String
    /// One human-readable line per failed check.
    public let checks: [String]

    public init(kind: String, checks: [String]) {
        self.kind = kind
        self.checks = checks
    }

    public var description: String {
        (["The \(kind) backend diverged from the AscendantBackend contract:"]
            + checks.map { "  - \($0)" }).joined(separator: "\n")
    }
}

/// Collects conformance failures for one check group.
public struct AscendantConformanceChecks {
    private let kind: String
    private var failures: [String] = []

    public init(kind: String) {
        self.kind = kind
    }

    /// Records a failure when `condition` is false.
    public mutating func require(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { failures.append(message()) }
    }

    /// Throws once if any check failed.
    public func finish() throws {
        if !failures.isEmpty {
            throw AscendantConformanceFailure(kind: kind, checks: failures)
        }
    }
}

/// Collects backend updates so the suite can assert what a client would see.
public actor AscendantConformanceUpdateSink: AscendantBackendUpdateSink {
    public private(set) var updates: [AscendantBackendUpdate] = []

    public init() {}

    public func append(_ update: AscendantBackendUpdate) async throws {
        updates.append(update)
    }

    /// Every text-bearing update, joined in order.
    public var combinedText: String { updates.compactMap(\.text).joined() }

    /// Whether any update marked the Turn terminal.
    public var hasTerminal: Bool { updates.contains { $0.terminal } }

    /// The update kinds in arrival order.
    public var kinds: [String] { updates.map(\.kind) }
}

/// Always approves a mediated permission request.
public actor AscendantConformancePermissionService: AscendantBackendPermissionService {
    public init() {}

    public func requestApproval(for _: BackendPermissionRequest) async -> AscendantPermissionDecision {
        .approved
    }
}

/// A host Workspace service backed by one advertised tool, so a backend can
/// project a real attachment.
@MainActor
public final class AscendantConformanceWorkspaceService: AscendantBackendWorkspaceService {
    /// The Workspace the suite attaches and detaches.
    public let reference: BackendWorkspaceReference

    public init(id: UUID = UUID()) {
        reference = BackendWorkspaceReference(
            id: id,
            uri: "echo://conformance",
            status: .available,
            tools: [BackendWorkspaceTool(
                id: "conformance_echo",
                name: "Conformance echo",
                description: "Echoes one value.",
                requiresPermission: false
            )]
        )
    }

    public func reference(id: UUID) async -> BackendWorkspaceReference? {
        id == reference.id ? reference : nil
    }

    public func invoke(_: BackendWorkspaceInvocation) async throws -> BackendWorkspaceResult {
        .init(message: "conformance")
    }
}

/// Signals when a stalled Turn has actually started, so cancellation is
/// measured against a running Turn rather than a race with startup.
public actor AscendantConformanceTurnSignal {
    private var started = false

    public init() {}

    /// Records that the fixture has begun handling a stalled Turn.
    public func markStarted() {
        started = true
    }

    /// Whether the fixture has begun the stalled Turn.
    public var hasStarted: Bool { started }

    /// Polls until the fixture begins the stalled Turn, or the timeout elapses.
    ///
    /// - Parameter timeout: The bound on waiting.
    /// - Returns: Whether the Turn started before the timeout.
    public func waitUntilStarted(timeout: Duration = .seconds(15)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if started { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return started
    }
}

/// A MainActor cell the conformance suites and fixtures share.
@MainActor
public final class AscendantConformanceBackendBox: Sendable {
    private var stored: (any AscendantBackend)?

    public init() {}

    /// The most recently constructed backend.
    public var backend: (any AscendantBackend)? { stored }

    /// Records the backend a fixture just constructed.
    public func hold(_ backend: any AscendantBackend) {
        stored = backend
    }
}

/// One backend kind under conformance.
///
/// A test target supplies the constructions; the suite supplies the
/// assertions. Every closure is `@MainActor` because ``AscendantBackend`` is.
@MainActor
public struct AscendantConformanceFixture: Sendable {
    /// The manifest backend kind under test.
    public let kind: String
    /// Optional surfaces this kind implements.
    public let surfaces: AscendantConformanceSurfaces
    /// The Workspace service the backend was built with, when it consumes one.
    public let workspaceService: AscendantConformanceWorkspaceService?
    /// The reply the fixture's backend returns for a plain message.
    public let expectedReply: @MainActor @Sendable (_ message: String) -> String
    /// Resolves once the fixture's backend has begun a stalled Turn.
    public let awaitTurnStarted: @MainActor @Sendable () async -> Void
    /// The bound within which a cancelled Turn must settle.
    public let cancellationBound: Duration
    /// Builds a fresh backend for one Ascendant and its Timelines.
    public let makeBackend: @MainActor @Sendable (_ ascendant: NodeManifest.Ascendant, _ timelines: [NodeManifest.Timeline]) async throws -> any AscendantBackend

    public init(
        kind: String,
        surfaces: AscendantConformanceSurfaces = [],
        workspaceService: AscendantConformanceWorkspaceService? = nil,
        expectedReply: @escaping @MainActor @Sendable (_ message: String) -> String = { AscendantConformanceReply.make(for: $0) },
        awaitTurnStarted: @escaping @MainActor @Sendable () async -> Void = { try? await Task.sleep(for: .milliseconds(250)) },
        cancellationBound: Duration = .seconds(5),
        makeBackend: @escaping @MainActor @Sendable (_ ascendant: NodeManifest.Ascendant, _ timelines: [NodeManifest.Timeline]) async throws -> any AscendantBackend
    ) {
        self.kind = kind
        self.surfaces = surfaces
        self.workspaceService = workspaceService
        self.expectedReply = expectedReply
        self.awaitTurnStarted = awaitTurnStarted
        self.cancellationBound = cancellationBound
        self.makeBackend = makeBackend
    }

    /// The contract suite for this fixture.
    public func suite() -> AscendantBackendConformanceSuite {
        .init(fixture: self)
    }
}

/// A host-level fixture: the per-kind runtime composition plus the way to make
/// the live backend report ``AscendantBackendError/lifecycleUnusable(_:)``.
@MainActor
public struct AscendantHostConformanceFixture: Sendable {
    /// The manifest backend kind under test.
    public let kind: String
    /// Builds adapters that construct this kind. A new backend per call.
    public let makeAdapters: @MainActor @Sendable () -> NodeRuntimeAdapters
    /// Makes the live backend's next Turn fail as lifecycle-unusable.
    public let breakLiveBackend: @MainActor @Sendable () async -> Void

    public init(
        kind: String,
        makeAdapters: @escaping @MainActor @Sendable () -> NodeRuntimeAdapters,
        breakLiveBackend: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.kind = kind
        self.makeAdapters = makeAdapters
        self.breakLiveBackend = breakLiveBackend
    }

    /// The host suite for this fixture.
    public func suite() -> AscendantHostConformanceSuite {
        .init(fixture: self)
    }
}
