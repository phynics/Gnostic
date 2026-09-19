// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PKContracts

/// Identifies one incubator integrator implementation and the contract it
/// implements.
///
/// The descriptor is host-facing metadata: it names the integrator, states the
/// proposal schema version the host must understand, and bounds the work the
/// host will accept. An integrator that does not match the host's supported
/// schema version is rejected before any integration runs.
public struct AtlasIntegratorDescriptor: Codable, Equatable, Hashable, Sendable {
    /// The proposal schema version the host supports for this issue.
    public static let currentSchemaVersion = 1

    /// A stable, bounded integrator name.
    public let identifier: String
    /// An opaque integrator release version.
    public let version: String
    /// The proposal schema version this integrator emits.
    public let schemaVersion: Int
    /// The maximum captured reports a single integration may receive.
    public let maximumInputReports: Int
    /// The maximum operations a single proposal may contain.
    public let maximumOperations: Int
    /// The maximum bytes of untrusted prose a proposal may carry.
    public let maximumProseBytes: Int

    /// Creates an integrator descriptor.
    public init(
        identifier: String,
        version: String,
        schemaVersion: Int = AtlasIntegratorDescriptor.currentSchemaVersion,
        maximumInputReports: Int = 64,
        maximumOperations: Int = 64,
        maximumProseBytes: Int = 512
    ) {
        self.identifier = identifier
        self.version = version
        self.schemaVersion = schemaVersion
        self.maximumInputReports = maximumInputReports
        self.maximumOperations = maximumOperations
        self.maximumProseBytes = maximumProseBytes
    }
}

/// The immutable, host-owned input handed to an integrator.
///
/// The request carries one immutable capture plus the descriptor's budgets, so
/// the integrator cannot widen its own authority. The value crosses the store
/// actor boundary and is never mutated afterwards.
public struct AtlasIntegrationRequest: Equatable, Sendable {
    /// The immutable captured state, Shard catalog, and report interval.
    public let capture: AtlasIntegrationCapture
    /// The maximum operations the host will accept.
    public let maximumOperations: Int
    /// The maximum bytes of untrusted prose the host will accept.
    public let maximumProseBytes: Int

    /// Creates an integration request.
    public init(capture: AtlasIntegrationCapture, maximumOperations: Int, maximumProseBytes: Int) {
        self.capture = capture
        self.maximumOperations = maximumOperations
        self.maximumProseBytes = maximumProseBytes
    }
}

/// The untrusted operations an integrator proposes for one capture.
///
/// Nothing here is authoritative. Identities, provenance, applicability, and
/// disclosure are re-derived and re-validated by the host before a patch
/// reaches the store. Prose never becomes runtime authority.
public struct AtlasIntegrationProposal: Codable, Equatable, Sendable {
    /// The proposed typed operations.
    public let operations: [AtlasPatchOperation]
    /// Optional bounded rationale. It is validated for size and otherwise
    /// discarded; it never reaches accepted state or diagnostics.
    public let rationale: String

    /// Creates an integrator proposal.
    public init(operations: [AtlasPatchOperation], rationale: String = "") {
        self.operations = operations
        self.rationale = rationale
    }
}

/// The pluggable incubator seam that turns captured reports into proposals.
///
/// The host invokes the integrator outside the store actor with an immutable
/// request. The initial slice ships fixture and no-op integrators and requires
/// no external model.
public protocol AtlasIntegrator: Sendable {
    /// The descriptor that bounds this integrator.
    var descriptor: AtlasIntegratorDescriptor { get }
    /// Integrates one immutable capture into an untrusted proposal.
    func integrate(_ request: AtlasIntegrationRequest) async throws -> AtlasIntegrationProposal
}

/// A deterministic integrator that consumes the captured cut without changing
/// semantic state. It proves watermark-only commits.
public struct AtlasNoOpIntegrator: AtlasIntegrator {
    /// The no-op descriptor.
    public let descriptor: AtlasIntegratorDescriptor

    /// Creates a no-op integrator.
    public init(descriptor: AtlasIntegratorDescriptor = AtlasIntegratorDescriptor(
        identifier: "atlas.noop",
        version: "1"
    )) {
        self.descriptor = descriptor
    }

    /// Returns a single no-op operation.
    public func integrate(_ request: AtlasIntegrationRequest) async throws -> AtlasIntegrationProposal {
        AtlasIntegrationProposal(operations: [.noOp])
    }
}

/// A fixture integrator that runs a caller-supplied closure. Tests and the
/// opt-in E2E slice use it as a deterministic stand-in for a real incubator.
public struct AtlasFixtureIntegrator: AtlasIntegrator {
    /// The fixture descriptor.
    public let descriptor: AtlasIntegratorDescriptor
    private let body: @Sendable (AtlasIntegrationRequest) async throws -> AtlasIntegrationProposal

    /// Creates a fixture integrator.
    public init(
        descriptor: AtlasIntegratorDescriptor = AtlasIntegratorDescriptor(
            identifier: "atlas.fixture",
            version: "1"
        ),
        body: @escaping @Sendable (AtlasIntegrationRequest) async throws -> AtlasIntegrationProposal
    ) {
        self.descriptor = descriptor
        self.body = body
    }

    /// Runs the fixture body.
    public func integrate(_ request: AtlasIntegrationRequest) async throws -> AtlasIntegrationProposal {
        try await body(request)
    }
}

/// Redacted, host-produced diagnostics for one accepted change.
///
/// The diagnostic carries versions and counts only. Report content, item
/// values, conflict summaries, directive values, and integrator rationale are
/// deliberately absent, so publishing a diagnostic cannot leak payload.
public struct AtlasAcceptedChangeDiagnostic: Codable, Equatable, Hashable, Sendable {
    /// The owning Ascendant.
    public let ascendantID: UUID
    /// The accepted patch identity.
    public let patchID: AtlasPatchID
    /// The capture the patch was built from.
    public let captureID: AtlasCaptureID
    /// The version before acceptance.
    public let baseVersion: AtlasVersion
    /// The version after acceptance.
    public let resultingVersion: AtlasVersion
    /// Whether the patch changed prompt-visible semantic state.
    public let isSemantic: Bool
    /// The number of normalized operations.
    public let operationCount: Int
    /// The number of consumed captured reports.
    public let consumedReportCount: Int
    /// The accepted item count after the commit.
    public let itemCount: Int
    /// The accepted conflict count after the commit.
    public let conflictCount: Int
    /// The accepted directive count after the commit.
    public let directiveCount: Int
    /// The integrator that produced the proposal.
    public let integratorIdentifier: String
    /// The integrator release version.
    public let integratorVersion: String
    /// The 1-based attempt that committed. `2` means one stale retry.
    public let attempt: Int
    /// Whether the store returned an already accepted patch.
    public let wasIdempotent: Bool

    /// Creates an accepted-change diagnostic.
    public init(
        ascendantID: UUID,
        patchID: AtlasPatchID,
        captureID: AtlasCaptureID,
        baseVersion: AtlasVersion,
        resultingVersion: AtlasVersion,
        isSemantic: Bool,
        operationCount: Int,
        consumedReportCount: Int,
        itemCount: Int,
        conflictCount: Int,
        directiveCount: Int,
        integratorIdentifier: String,
        integratorVersion: String,
        attempt: Int,
        wasIdempotent: Bool
    ) {
        self.ascendantID = ascendantID
        self.patchID = patchID
        self.captureID = captureID
        self.baseVersion = baseVersion
        self.resultingVersion = resultingVersion
        self.isSemantic = isSemantic
        self.operationCount = operationCount
        self.consumedReportCount = consumedReportCount
        self.itemCount = itemCount
        self.conflictCount = conflictCount
        self.directiveCount = directiveCount
        self.integratorIdentifier = integratorIdentifier
        self.integratorVersion = integratorVersion
        self.attempt = attempt
        self.wasIdempotent = wasIdempotent
    }
}

/// A host seam that receives redacted accepted-change diagnostics.
public protocol AtlasAcceptedChangeObserver: Sendable {
    /// Observes one accepted change.
    func accept(_ diagnostic: AtlasAcceptedChangeDiagnostic) async
}

/// An observer that discards diagnostics.
public struct AtlasNullAcceptedChangeObserver: AtlasAcceptedChangeObserver {
    /// Creates a null observer.
    public init() {}

    /// Discards the diagnostic.
    public func accept(_ diagnostic: AtlasAcceptedChangeDiagnostic) async {}
}

/// The outcome of one explicit integration flush.
public enum AtlasIntegrationOutcome: Equatable, Sendable {
    /// The host accepted a patch.
    case committed(receipt: AtlasCommitReceipt, diagnostic: AtlasAcceptedChangeDiagnostic)
    /// No captured reports were pending, so no commit was needed.
    case noWork

    /// The accepted patch, when a commit happened.
    public var receipt: AtlasCommitReceipt? {
        if case let .committed(receipt, _) = self { return receipt }
        return nil
    }

    /// The published diagnostic, when a commit happened.
    public var diagnostic: AtlasAcceptedChangeDiagnostic? {
        if case let .committed(_, diagnostic) = self { return diagnostic }
        return nil
    }
}

/// Structured failures raised by Atlas host validation and coordination.
public enum AtlasIntegrationError: Error, Equatable, Sendable, PKError {
    /// The captured accepted state schema is not supported.
    case unsupportedStateSchema(expected: Int, actual: Int)
    /// The integrator proposal schema is not supported.
    case unsupportedIntegratorSchema(expected: Int, actual: Int)
    /// The integrator descriptor is empty or its budgets are invalid.
    case invalidIntegratorDescriptor
    /// A value belongs to a different Ascendant.
    case identityMismatch
    /// The capture is not internally consistent.
    case captureMismatch
    /// The captured watermark cut is inconsistent.
    case watermarkMismatch
    /// An operation references a report outside the captured interval.
    case inputMembership
    /// A proposal exceeds an integrator budget.
    case budgetExceeded
    /// Provenance is untrusted or inconsistent.
    case invalidProvenance
    /// The proposed epistemic status is not allowed from integration.
    case invalidEpistemicStatus
    /// Applicability references an unknown Shard or is not conservative.
    case invalidApplicability
    /// Disclosure broadens past applicability or references an unknown Shard.
    case invalidDisclosure
    /// The proposed lifecycle transition is not allowed.
    case invalidLifecycle
    /// The proposed supersession is not monotonic.
    case invalidSupersession
    /// A retraction is malformed.
    case invalidRetraction
    /// A conflict operation is malformed.
    case invalidConflict
    /// A directive operation is malformed.
    case invalidDirective
    /// A proposal repeats an operation address.
    case duplicateOperation
    /// The proposal tries to claim host-only authority.
    case authorityViolation
    /// A patch references an unknown accepted object.
    case invalidReference
    /// Consumption is not exact or not monotonic.
    case nonMonotonicConsumption
    /// A semantic key is empty or too long.
    case invalidItemKey

    public var errorDomain: String { "me.atkn.gnostic.positronic-atlas" }

    public var errorCode: Int {
        switch self {
        case .unsupportedStateSchema: 7101
        case .unsupportedIntegratorSchema: 7102
        case .invalidIntegratorDescriptor: 7103
        case .identityMismatch: 7104
        case .captureMismatch: 7105
        case .watermarkMismatch: 7106
        case .inputMembership: 7107
        case .budgetExceeded: 7108
        case .invalidProvenance: 7109
        case .invalidEpistemicStatus: 7110
        case .invalidApplicability: 7111
        case .invalidDisclosure: 7112
        case .invalidLifecycle: 7113
        case .invalidSupersession: 7114
        case .invalidRetraction: 7115
        case .invalidConflict: 7116
        case .invalidDirective: 7117
        case .duplicateOperation: 7118
        case .authorityViolation: 7119
        case .invalidReference: 7120
        case .nonMonotonicConsumption: 7121
        case .invalidItemKey: 7122
        }
    }

    /// A stable machine-readable failure label.
    public var reasonCode: String {
        switch self {
        case .unsupportedStateSchema: "unsupportedStateSchema"
        case .unsupportedIntegratorSchema: "unsupportedIntegratorSchema"
        case .invalidIntegratorDescriptor: "invalidIntegratorDescriptor"
        case .identityMismatch: "identityMismatch"
        case .captureMismatch: "captureMismatch"
        case .watermarkMismatch: "watermarkMismatch"
        case .inputMembership: "inputMembership"
        case .budgetExceeded: "budgetExceeded"
        case .invalidProvenance: "invalidProvenance"
        case .invalidEpistemicStatus: "invalidEpistemicStatus"
        case .invalidApplicability: "invalidApplicability"
        case .invalidDisclosure: "invalidDisclosure"
        case .invalidLifecycle: "invalidLifecycle"
        case .invalidSupersession: "invalidSupersession"
        case .invalidRetraction: "invalidRetraction"
        case .invalidConflict: "invalidConflict"
        case .invalidDirective: "invalidDirective"
        case .duplicateOperation: "duplicateOperation"
        case .authorityViolation: "authorityViolation"
        case .invalidReference: "invalidReference"
        case .nonMonotonicConsumption: "nonMonotonicConsumption"
        case .invalidItemKey: "invalidItemKey"
        }
    }

    /// A safe message for ErrorKit and user-facing adapters. Item keys, values,
    /// summaries, and rationale are intentionally absent.
    public var userFriendlyMessage: String {
        switch self {
        case .unsupportedStateSchema: "The captured Atlas state schema is not supported."
        case .unsupportedIntegratorSchema: "The Atlas integrator proposal schema is not supported."
        case .invalidIntegratorDescriptor: "The Atlas integrator descriptor is invalid."
        case .identityMismatch: "The Atlas proposal belongs to a different Ascendant."
        case .captureMismatch: "The Atlas integration capture is not internally consistent."
        case .watermarkMismatch: "The Atlas captured watermark cut is invalid."
        case .inputMembership: "The Atlas proposal references input outside the captured interval."
        case .budgetExceeded: "The Atlas proposal exceeds an integration budget."
        case .invalidProvenance: "The Atlas proposal carries invalid provenance."
        case .invalidEpistemicStatus: "The Atlas proposal claims an unsupported epistemic status."
        case .invalidApplicability: "The Atlas proposal carries invalid applicability."
        case .invalidDisclosure: "The Atlas proposal broadens disclosure past applicability."
        case .invalidLifecycle: "The Atlas proposal carries an invalid lifecycle transition."
        case .invalidSupersession: "The Atlas proposal supersedes retracted state."
        case .invalidRetraction: "The Atlas proposal carries an invalid retraction."
        case .invalidConflict: "The Atlas proposal carries an invalid conflict operation."
        case .invalidDirective: "The Atlas proposal carries an invalid directive operation."
        case .duplicateOperation: "The Atlas proposal repeats an operation address."
        case .authorityViolation: "The Atlas proposal attempts to claim host-only authority."
        case .invalidReference: "The Atlas proposal references an unknown Atlas object."
        case .nonMonotonicConsumption: "The Atlas proposal does not consume the captured cut exactly."
        case .invalidItemKey: "The Atlas proposal carries an invalid semantic key."
        }
    }

    /// The safe public message spelling used by Gnostic adapters.
    public var publicMessage: String { userFriendlyMessage }
}
