// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Pinned ACP v2 protocol baseline declarations and invariants.
///
/// Implements ADR 0019 (ACP v2 as Gnostic's protocol baseline) and
/// ADR 0021 (Gnostic v0.5 Architecture Reconciliation).
public enum ACPv2Protocol {
    /// Pinned Git commit hash of the agent-client-protocol schema revision.
    public static let schemaRevision = "39ae6a2"
    public static let pinnedSchemaRevision = schemaRevision
    public static let isOptInPreview = true

    /// The ACP wire protocol version supported by this implementation.
    public static let protocolVersion = 2

    /// The compatibility status of the ACP v2 implementation in Gnostic v0.5.
    /// In accordance with ADR 0019 T2, ACP v2 is shipped as an opt-in v2 preview.
    public static let compatibilityStatus = "preview"

    /// Canonical ACP version tag for recording in envelopes and ledger records.
    public static let versionTag = "acp-v\(protocolVersion)@\(schemaRevision)"

    // MARK: - Standard Agent Methods (Incoming from Client to Agent)
    public enum AgentMethod {
        public static let initialize = "initialize"
        public static let sessionNew = "session/new"
        public static let sessionPrompt = "session/prompt"
        public static let sessionCancel = "session/cancel"
        public static let sessionResume = "session/resume"
        public static let sessionClose = "session/close"
        public static let sessionList = "session/list"
        public static let sessionDelete = "session/delete"
        public static let sessionSetConfigOption = "session/set_config_option"
    }

    // MARK: - Standard Client Methods (Incoming from Agent to Client)
    public enum ClientMethod {
        public static let sessionUpdate = "session/update"
        public static let sessionRequestPermission = "session/request_permission"
    }

    // MARK: - Standard Protocol-level Methods
    public enum ProtocolMethod {
        public static let cancelRequest = "$/cancel_request"
    }

    // MARK: - Standard Error Codes
    public enum ErrorCode {
        /// Invalid JSON was received by the server (-32700).
        public static let parseError = -32700
        /// The JSON sent is not a valid Request object (-32600).
        public static let invalidRequest = -32600
        /// The method does not exist or is not available (-32601).
        public static let methodNotFound = -32601
        /// Invalid method parameter(s) (-32602).
        public static let invalidParams = -32602
        /// Internal JSON-RPC error (-32603).
        public static let internalError = -32603
        /// Executing party internal cancellation (-32800). An unanswered permission request
        /// uses the `cancelled` outcome instead (ADR 0019 Decision T3).
        public static let requestCancelled = -32800
        /// Timeline busy error code (-32001).
        /// Required by ADR 0021 Section 4.
        public static let timelineBusy = -32001
        /// Protocol version mismatch or unsupported protocol version.
        public static let unsupportedProtocolVersion = -32000
        public static let protocolVersionMismatch = unsupportedProtocolVersion
    }

    // MARK: - Strict ACP v1 Rejection (ADR 0019 Decision T1)
    /// Validates an incoming protocol version against the pinned ACP v2 baseline.
    /// Strictly rejects ACP v1 with an explicit error.
    ///
    /// - Parameter version: The integer protocol version sent by a client or runtime.
    /// - Throws: ``ACPError.unsupportedProtocolVersion`` if the version is not v2.
    public static func validateProtocolVersion(_ version: Int) throws {
        if version < 2 {
            throw ACPError.unsupportedProtocolVersion(
                "ACP v1 is strictly rejected (ADR 0019 T1). Gnostic requires ACP v2 or higher."
            )
        }
    }
}
