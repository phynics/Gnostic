// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation

/// The failure vocabulary every public consumer client error shares.
///
/// A client error enum conforms through its `providerMismatch` and
/// `callFailed(reasonCode:statusCode:retryable:)` cases, so
/// ``GnosticCallChannel`` throws the caller's own public error type without a
/// per-client mapping.
protocol GnosticClientCallFailure: Error {
    static var providerMismatch: Self { get }
    static func callFailed(reasonCode: String, statusCode: Int, retryable: Bool) -> Self
}

extension GnosticTurnClientError: GnosticClientCallFailure {}
extension GnosticWorkspaceClientError: GnosticClientCallFailure {}
extension GnosticTimelineClientError: GnosticClientCallFailure {}

/// One provider-addressed unary Call/Return exchange for the public consumer
/// clients.
///
/// The channel encodes the request within the wire payload budget, filters the
/// call to the addressed provider, rejects a response from any other provider,
/// and decodes the result. Failures are normalized into `Failure`:
///
/// - a serve's ``GnosticProtocolFailure`` keeps its reason, status, and
///   retryability; a bare remote failure is `callFailed` with its status;
/// - a transport timeout is `callTimedOut` (504, retryable), a cancellation is
///   `callCancelled` (499), and any other transport failure is
///   `transportFailure` (503, retryable);
/// - an undecodable result is `invalidResponse` (502).
///
/// Request validation errors from ``GnosticWirePayload`` propagate unchanged.
@MainActor
struct GnosticCallChannel<Failure: GnosticClientCallFailure> {
    let manager: CommunicationManager

    func call<Request: Encodable, Response: Decodable>(
        _ operation: String,
        request: Request,
        context: String,
        providerID: String,
        timeout: Duration,
        returning _: Response.Type = Response.self
    ) async throws -> Response {
        let payload = try GnosticWirePayload.encode(request, context: context)
        let response: UnaryCallResult
        do {
            response = try await manager.call(
                operation: operation,
                parameters: String(decoding: payload, as: UTF8.self),
                context: .provider(providerID),
                timeout: timeout
            )
        } catch let failure as RemoteCallFailure {
            throw Self.remoteFailure(failure)
        } catch let error as AxolotyError {
            throw Self.transportFailure(error)
        }
        guard response.sourceId?.lowercased() == providerID.lowercased() else {
            throw Failure.providerMismatch
        }
        do {
            return try JSONDecoder().decode(Response.self, from: Data(response.result.utf8))
        } catch {
            throw Failure.callFailed(reasonCode: "invalidResponse", statusCode: 502, retryable: false)
        }
    }

    static func remoteFailure(_ failure: RemoteCallFailure) -> Failure {
        let decoded = try? JSONDecoder().decode(GnosticProtocolFailure.self, from: Data(failure.message.utf8))
        return .callFailed(
            reasonCode: decoded?.reasonCode ?? "callFailed",
            statusCode: decoded?.statusCode ?? failure.code,
            retryable: decoded?.retryable ?? false
        )
    }

    static func transportFailure(_ error: AxolotyError) -> Failure {
        if case let .runtime(code, _) = error {
            switch code {
            case .timedOut:
                return .callFailed(reasonCode: "callTimedOut", statusCode: 504, retryable: true)
            case .cancelled:
                return .callFailed(reasonCode: "callCancelled", statusCode: 499, retryable: false)
            default:
                break
            }
        }
        return .callFailed(reasonCode: "transportFailure", statusCode: 503, retryable: true)
    }
}

/// How a catalog lookup resolved one advertised object to its provider.
enum GnosticProviderResolution: Equatable {
    case provider(String)
    case unavailable
    case ambiguous
    case mismatch
}

/// The session catalog reads the public consumer clients share.
///
/// A lookup reads the catalog first and issues one active discover request
/// only when the object is absent.
@MainActor
struct GnosticCatalogLookup {
    let manager: CommunicationManager
    let catalog: NetworkCatalog
    let subscription: GnosticSubscription
    let timeout: Duration

    /// Issues one active discover request and ingests its responses.
    func refresh() async {
        await subscription.discover(using: manager, timeout: timeout)
    }

    /// Returns the catalog, refreshed once when no object of the given type and
    /// identifier is present.
    func entries(requiring objectType: String, id: UUID) async -> [NetworkCatalogEntry] {
        let entries = await catalog.networkObjects()
        guard !entries.contains(where: { $0.objectType == objectType && $0.objectID == id }) else {
            return entries
        }
        await refresh()
        return await catalog.networkObjects()
    }

    /// Resolves the single provider advertising an object, checked against an
    /// optional expected provider.
    static func provider(
        of objectType: String,
        id: UUID,
        in entries: [NetworkCatalogEntry],
        expected explicitProviderID: String? = nil
    ) -> GnosticProviderResolution {
        let matches = entries.filter { $0.objectType == objectType && $0.objectID == id }
        guard let providerID = matches.first?.providerID else { return .unavailable }
        guard Set(matches.map { $0.providerID.lowercased() }).count == 1 else { return .ambiguous }
        if let explicitProviderID, explicitProviderID.caseInsensitiveCompare(providerID) != .orderedSame {
            return .mismatch
        }
        return .provider(providerID)
    }

    /// Returns the Ascendant a provider reports as operating a Timeline, or
    /// `nil` unless exactly one is reported.
    static func operatingAscendantID(
        ofTimeline timelineID: UUID,
        providerID: String,
        in entries: [NetworkCatalogEntry]
    ) -> UUID? {
        let ascendantIDs = Set(entries.compactMap { entry -> UUID? in
            guard entry.objectType == GnosticObjectType.timeline,
                  entry.objectID == timelineID,
                  entry.providerID.caseInsensitiveCompare(providerID) == .orderedSame
            else { return nil }
            return entry.attachedAscendantID
        })
        return ascendantIDs.count == 1 ? ascendantIDs.first : nil
    }

    /// Reports whether a provider advertises an Ascendant with a capability,
    /// optionally restricted to one Ascendant.
    static func ascendantAdvertises(
        _ capability: String,
        ascendantID: UUID? = nil,
        providerID: String,
        in entries: [NetworkCatalogEntry]
    ) -> Bool {
        entries.contains { entry in
            entry.objectType == GnosticObjectType.ascendant
                && (ascendantID == nil || entry.objectID == ascendantID)
                && entry.providerID.caseInsensitiveCompare(providerID) == .orderedSame
                && entry.advertisedCapabilities.contains(capability)
        }
    }
}

extension NetworkCatalogEntry {
    /// The capability names the advertisement declares.
    var advertisedCapabilities: [String] {
        guard case let .array(values) = knownProperties["capabilities"] else { return [] }
        return values.compactMap { value in
            guard case let .string(capability) = value else { return nil }
            return capability
        }
    }

    /// The Ascendant a Timeline advertisement names as its operator.
    var attachedAscendantID: UUID? {
        guard case let .string(raw) = knownProperties["attachedAscendantID"] else { return nil }
        return UUID(uuidString: raw)
    }
}

extension ObjectFilter {
    /// A call context that addresses one provider identity.
    static func provider(_ providerID: String) -> ObjectFilter {
        ObjectFilter(condition: ObjectFilterCondition(
            property: ObjectFilterProperty("objectId"),
            expression: .equals(FilterOperand(providerID.lowercased()))
        ))
    }
}
