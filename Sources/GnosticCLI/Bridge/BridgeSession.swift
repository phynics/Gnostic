// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PKShared

/// Errors a method dispatcher can expose as a JSON-RPC protocol error.
public enum BridgeMethodError: Error, Sendable {
    case invalidParams(String)
    case methodNotFound(String)
    case invalidState(String)
    case internalError(String)
}

/// A single JSON-RPC session. It owns framing, lifecycle state, and request
/// cancellation; the injected handler owns domain semantics.
public actor BridgeSession {
    public enum State: Sendable, Equatable {
        case awaitingInitialize
        case initialized
        case stopped
    }

    public typealias RequestHandler = @Sendable (JSONRPCRequest) async throws -> AnyCodable
    public typealias InitializeHandler = @Sendable () async throws -> AnyCodable
    public typealias ResponseHandler = @Sendable (JSONRPCResponse) async -> Void
    public typealias Output = @Sendable (Data) -> Void

    private var framer = LFMessageFramer()
    private var state: State = .awaitingInitialize
    private var requests: [JSONRPCIdentifier: Task<Void, Never>] = [:]
    private let handler: RequestHandler
    private let initializeHandler: InitializeHandler
    private let responseHandler: ResponseHandler?
    private let output: Output

    public init(handler: @escaping RequestHandler, output: @escaping Output) {
        self.init(handler: handler, output: output, initialize: {
            .dictionary([
                "protocolVersion": .string("1"),
                "capabilities": .dictionary(["cancellation": .boolean(true)]),
            ])
        })
    }

    public init(
        handler: @escaping RequestHandler,
        output: @escaping Output,
        initialize: @escaping InitializeHandler,
        notification: @escaping Output = { _ in },
        response: ResponseHandler? = nil
    ) {
        self.handler = handler
        initializeHandler = initialize
        self.output = output
        self.notification = notification
        responseHandler = response
    }

    private let notification: Output

    public func currentState() -> State { state }

    /// Accepts arbitrary stdin chunks; complete LF-delimited messages are
    /// dispatched while partial messages remain buffered.
    public func receive(_ data: Data) async {
        for frame in framer.append(data) {
            await receiveFrame(frame)
        }
    }

    /// Finishes the stream and emits a parse error for an incomplete frame.
    public func finish() async {
        do {
            try framer.finish()
        } catch {
            emit(JSONRPCResponse(id: nil, error: errorObject(code: .parseError, message: "Incomplete JSON-RPC frame")))
        }
        cancelAll()
        state = .stopped
    }

    /// Emits a JSON-RPC notification without an id. ACP uses notifications for
    /// streamed session updates while the prompt request remains in flight.
    public func sendNotification(method: String, params: AnyCodable? = nil) {
        let request = JSONRPCRequest(id: nil, method: method, params: params)
        guard let data = try? JSONEncoder().encode(request) else { return }
        notification(data + Data([0x0A]))
    }

    private func receiveFrame(_ frame: Data) async {
        if let response = try? JSONDecoder().decode(JSONRPCResponse.self, from: frame) {
            await responseHandler?(response)
            return
        }
        let request: JSONRPCRequest
        do {
            request = try JSONDecoder().decode(JSONRPCRequest.self, from: frame)
        } catch let error as JSONRPCProtocolError {
            emit(JSONRPCResponse(id: nil, error: errorObject(code: .invalidRequest, message: String(describing: error))))
            return
        } catch {
            emit(JSONRPCResponse(id: nil, error: errorObject(code: .parseError, message: "Invalid JSON")))
            return
        }

        switch request.method {
        case "initialize":
            await initialize(request)
        case "shutdown":
            await shutdown(request)
        case "exit":
            await exit(request)
        case "$/cancelRequest":
            cancel(request)
        default:
            guard state == .initialized else {
                respondIfNeeded(to: request, error: errorObject(code: .invalidState, message: "initialize must complete first"))
                return
            }
            guard request.id != nil else {
                Task { [handler] in _ = try? await handler(request) }
                return
            }
            await start(request)
        }
    }

    private func initialize(_ request: JSONRPCRequest) async {
        guard state == .awaitingInitialize else {
            respondIfNeeded(to: request, error: errorObject(code: .invalidState, message: "session is already initialized"))
            return
        }
        do {
            let result = try await initializeHandler()
            state = .initialized
            respondIfNeeded(to: request, result: result)
        } catch {
            respondIfNeeded(to: request, error: JSONRPCErrorObject(
                code: JSONRPCErrorCode.internalError.rawValue,
                message: "Initialization failed"
            ))
        }
    }

    private func shutdown(_ request: JSONRPCRequest) async {
        guard state == .initialized else {
            respondIfNeeded(to: request, error: errorObject(code: .invalidState, message: "session is not initialized"))
            return
        }
        state = .stopped
        cancelAll()
        respondIfNeeded(to: request, result: .dictionary([:]))
    }

    private func exit(_ request: JSONRPCRequest) async {
        cancelAll()
        state = .stopped
        respondIfNeeded(to: request, result: .dictionary([:]))
    }

    private func cancel(_ request: JSONRPCRequest) {
        guard let params = request.params,
              case let .dictionary(fields) = params,
              let idValue = fields["id"],
              let id = identifier(from: idValue) else {
            respondIfNeeded(to: request, error: errorObject(code: .invalidParams, message: "cancel request requires an id"))
            return
        }
        requests[id]?.cancel()
    }

    private func start(_ request: JSONRPCRequest) async {
        guard let id = request.id else { return }
        guard requests[id] == nil else {
            respondIfNeeded(to: request, error: errorObject(code: .invalidRequest, message: "request id is already in flight"))
            return
        }
        let task = Task.detached { [handler, weak self] in
            do {
                let result = try await handler(request)
                guard !Task.isCancelled else { return }
                await self?.complete(id: id, response: JSONRPCResponse(id: id, result: result))
            } catch is CancellationError {
                await self?.complete(id: id, response: nil)
            } catch let error as BridgeMethodError {
                guard !Task.isCancelled else { return }
                await self?.complete(id: id, response: JSONRPCResponse(id: id, error: self?.errorObject(for: error) ?? JSONRPCErrorObject(code: JSONRPCErrorCode.internalError.rawValue, message: "Internal error")))
            } catch let error as RemoteChatClientError {
                guard !Task.isCancelled else { return }
                await self?.complete(id: id, response: JSONRPCResponse(id: id, error: self?.errorObject(for: error) ?? JSONRPCErrorObject(code: JSONRPCErrorCode.internalError.rawValue, message: "Internal error")))
            } catch {
                guard !Task.isCancelled else { return }
                await self?.complete(id: id, response: JSONRPCResponse(id: id, error: JSONRPCErrorObject(code: JSONRPCErrorCode.internalError.rawValue, message: "Internal error")))
            }
        }
        requests[id] = task
    }

    private func complete(id: JSONRPCIdentifier, response: JSONRPCResponse?) {
        requests[id] = nil
        if let response { emit(response) }
    }

    private func cancelAll() {
        for task in requests.values { task.cancel() }
        requests.removeAll()
    }

    private func respondIfNeeded(to request: JSONRPCRequest, result: AnyCodable) {
        guard let id = request.id else { return }
        emit(JSONRPCResponse(id: id, result: result))
    }

    private func respondIfNeeded(to request: JSONRPCRequest, error: JSONRPCErrorObject) {
        guard let id = request.id else { return }
        emit(JSONRPCResponse(id: id, error: error))
    }

    private func emit(_ response: JSONRPCResponse) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        output(data + Data([0x0A]))
    }

    private func errorObject(code: JSONRPCErrorCode, message: String) -> JSONRPCErrorObject {
        JSONRPCErrorObject(code: code.rawValue, message: message)
    }

    private func errorObject(for error: BridgeMethodError) -> JSONRPCErrorObject {
        switch error {
        case let .invalidParams(message): errorObject(code: .invalidParams, message: message)
        case let .methodNotFound(message): errorObject(code: .methodNotFound, message: message)
        case let .invalidState(message): errorObject(code: .invalidState, message: message)
        case let .internalError(message): errorObject(code: .internalError, message: message)
        }
    }

    private func errorObject(for error: RemoteChatClientError) -> JSONRPCErrorObject {
        let code: JSONRPCErrorCode = switch error {
        case .brokerUnreachable: .internalError
        case .noServedAgent, .workspaceUnavailable, .workspaceAmbiguous, .timelineNotAttached: .invalidState
        case .approvalRequired, .toolNotAdvertised, .invalidWorkspaceURI: .invalidParams
        }
        return JSONRPCErrorObject(
            code: code.rawValue,
            message: error.errorDescription ?? "Gnostic operation failed",
            data: .dictionary(["gnosticCode": .string(error.gnosticCode)])
        )
    }

    private func identifier(from value: AnyCodable) -> JSONRPCIdentifier? {
        switch value {
        case let .string(value): return .string(value)
        case let .number(value):
            guard value.isFinite, value.rounded() == value else { return nil }
            return .number(Int64(value))
        default: return nil
        }
    }
}
