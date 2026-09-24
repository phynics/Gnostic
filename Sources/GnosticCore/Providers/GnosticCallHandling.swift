// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation

extension CallHandlerResult {
    /// A bounded protocol failure whose Call code and body status agree.
    static func failure(code: Int, reasonCode: String, message: String, retryable: Bool = false) -> Self {
        .failure(
            code: code,
            message: GnosticProtocol.failureMessage(
                reasonCode: reasonCode,
                message: message,
                statusCode: code,
                retryable: retryable
            )
        )
    }

    /// The failure for a rejected protocol major.
    static func failure(_ error: GnosticProtocolError) -> Self {
        .failure(code: error.statusCode, message: error.failureMessage)
    }

    /// The failure for an error already mapped to its public form.
    static func failure(_ failure: GnosticPublicFailure) -> Self {
        .failure(code: failure.code, message: failure.message)
    }

    /// A success whose result is encoded within the embedded payload budget.
    static func encoded<T: Encodable>(_ value: T, context: String) throws -> Self {
        .success(result: String(decoding: try GnosticWirePayload.encode(value, context: context), as: UTF8.self))
    }
}

/// The request, execution, and pagination steps the serve-side Call handlers
/// share.
enum GnosticCallHandling {
    /// Validates the payload's protocol major.
    ///
    /// - Returns: `nil` when the major is compatible; otherwise the protocol
    ///   failure, or a 400 with the given reason when the payload cannot be
    ///   inspected.
    static func protocolFailure(
        _ parameters: String?,
        invalidReasonCode: String,
        invalidMessage: String
    ) -> CallHandlerResult? {
        do {
            try GnosticProtocol.validatePayload(parameters)
            return nil
        } catch let error as GnosticProtocolError {
            return .failure(error)
        } catch {
            return .failure(code: 400, reasonCode: invalidReasonCode, message: invalidMessage)
        }
    }

    /// Decodes a request payload, or returns `nil` when it is absent or invalid.
    static func decode<T: Decodable>(_ type: T.Type, from parameters: String?) -> T? {
        guard let parameters else { return nil }
        return try? JSONDecoder().decode(type, from: Data(parameters.utf8))
    }

    /// Runs one executor step and maps any failure except cancellation to its
    /// bounded public form.
    static func run(
        fallbackReasonCode: String,
        fallbackMessage: String,
        _ body: () async throws -> CallHandlerResult
    ) async throws -> CallHandlerResult {
        do {
            return try await body()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure(GnosticProtocol.publicFailure(
                for: error,
                fallbackCode: 500,
                fallbackReasonCode: fallbackReasonCode,
                fallbackMessage: fallbackMessage
            ))
        }
    }

    /// Returns the longest page from `offset` whose encoded result, including
    /// its continuation offset, fits the embedded payload budget.
    static func boundedPage<Item, Page: Encodable>(
        _ values: [Item],
        offset: Int,
        limit: Int,
        context: String,
        page makePage: ([Item], _ nextOffset: Int?) -> Page
    ) -> (items: [Item], nextOffset: Int?) {
        guard offset < values.count else { return ([], nil) }
        let pageLimit = min(limit, GnosticWirePayload.maximumListItems)
        var items: [Item] = []
        for value in values.dropFirst(offset).prefix(pageLimit) {
            let candidate = items + [value]
            guard (try? GnosticWirePayload.encode(
                makePage(candidate, nextOffset(offset: offset, count: candidate.count, total: values.count)),
                context: context
            )) != nil else { break }
            items = candidate
        }
        return (items, nextOffset(offset: offset, count: items.count, total: values.count))
    }

    /// Registers one handler for each operation and cancels every
    /// registration made so far when one fails.
    @MainActor
    static func register(
        operations: [String],
        on communication: CommunicationManager,
        context: CoatyObject?,
        handle: @escaping @Sendable (_ operation: String, _ parameters: String?) async throws -> CallHandlerResult
    ) async throws -> [CallHandlerRegistration] {
        var registrations: [CallHandlerRegistration] = []
        do {
            for operation in operations {
                registrations.append(try await communication.registerCallHandler(operation: operation, context: context) { request in
                    try await handle(operation, request.parameters)
                })
            }
        } catch {
            registrations.forEach { $0.cancel() }
            throw error
        }
        return registrations
    }

    private static func nextOffset(offset: Int, count: Int, total: Int) -> Int? {
        offset + count < total ? offset + count : nil
    }
}
