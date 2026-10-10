// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticProtocol

// The failure mapping stays in GnosticCore because it names kernel-domain
// errors (`NodeRuntimeError`, `AscendantBackendError`,
// `DiscoveredWorkspaceAttachmentError`). The wire envelope and its structured
// protocol failures live in `GnosticProtocol`.
extension GnosticProtocol {
    /// Maps an error to a bounded public failure without exposing arbitrary
    /// implementation details from an injected executor or transport.
    ///
    /// Structured domain failures retain their established status and reason
    /// code. Unknown failures use the supplied safe fallback message.
    public static func publicFailure(
        for error: Error,
        fallbackCode: Int,
        fallbackReasonCode: String,
        fallbackMessage: String
    ) -> GnosticPublicFailure {
        if let error = error as? GnosticProtocolError {
            return GnosticPublicFailure(code: error.statusCode, message: error.failureMessage)
        }
        if let error = error as? NodeRuntimeError {
            return GnosticPublicFailure(
                code: error.statusCode,
                message: failureMessage(reasonCode: error.reasonCode, message: error.publicMessage, statusCode: error.statusCode),
                retryable: false
            )
        }
        if let error = error as? AscendantTurnError {
            return GnosticPublicFailure(
                code: error.statusCode,
                message: failureMessage(reasonCode: error.reasonCode, message: error.publicMessage, statusCode: error.statusCode, retryable: error.retryable),
                retryable: error.retryable
            )
        }
        if let error = error as? AscendantBackendError {
            return GnosticPublicFailure(
                code: error.statusCode,
                message: failureMessage(reasonCode: error.reasonCode, message: backendPublicMessage(for: error), statusCode: error.statusCode),
                retryable: false
            )
        }
        if let error = error as? DiscoveredWorkspaceAttachmentError {
            switch error {
            case .approvalRequired:
                return GnosticPublicFailure(code: 403, message: failureMessage(reasonCode: "approvalRequired", message: "Workspace attachment requires approval.", statusCode: 403))
            case let .unavailable(status):
                return GnosticPublicFailure(code: 409, message: failureMessage(reasonCode: "workspaceUnavailable", message: "Workspace is not uniquely available (\(status)).", statusCode: 409))
            case .invalidURI:
                return GnosticPublicFailure(code: 422, message: failureMessage(reasonCode: "invalidWorkspaceURI", message: "Workspace advertised an invalid URI.", statusCode: 422))
            case let .timelineNotOwned(id):
                return GnosticPublicFailure(code: 404, message: failureMessage(reasonCode: "timelineNotOwned", message: "Timeline \(id.uuidString.lowercased()) is not owned by this Node.", statusCode: 404))
            }
        }
        return GnosticPublicFailure(code: fallbackCode, message: failureMessage(reasonCode: fallbackReasonCode, message: fallbackMessage, statusCode: fallbackCode))
    }

    private static func backendPublicMessage(for error: AscendantBackendError) -> String {
        switch error {
        case .invalidConfiguration:
            "The Ascendant backend configuration is invalid."
        case .timelineNotFound:
            "The Timeline was not found."
        case .terminal:
            "The Ascendant backend reported a terminal failure."
        case .cancelled:
            "The Ascendant turn was cancelled."
        case .lifecycleUnusable:
            "The Ascendant backend lifecycle is unavailable."
        case .capabilityUnavailable:
            "The Ascendant backend does not provide the requested optional capability."
        }
    }
}
