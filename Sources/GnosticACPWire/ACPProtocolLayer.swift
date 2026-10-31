// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Asynchronous JSON-RPC protocol layer managing ACP v2 requests, responses,
/// notifications, and timeout bounds over an abstract ``ACPTransport``.
public actor ACPProtocolLayer {
    private let transport: any ACPTransport
    private let defaultTimeoutSeconds: Double
    private var pendingRequests: [String: CheckedContinuation<ACPJSONRPCResponse, any Error>] = [:]
    private var requestHandlers: [String: @Sendable (ACPJSONRPCRequest) async throws -> ACPJSONRPCResponse] = [:]
    private var notificationHandlers: [String: [@Sendable (ACPJSONRPCNotification) async -> Void]] = [:]
    private var nextRequestID: Int64 = 1
    private var readerTask: Task<Void, Never>?
    private var isStarted = false
    private var isClosed = false

    public init(transport: any ACPTransport, defaultTimeoutSeconds: Double = 30.0) {
        self.transport = transport
        self.defaultTimeoutSeconds = defaultTimeoutSeconds
    }

    public func start() async throws {
        guard !isStarted else { return }
        isStarted = true
        try await transport.start()
        let messagesStream = transport.messages
        readerTask = Task { [weak self] in
            for await message in messagesStream {
                guard let self else { break }
                await self.handleIncomingMessage(message)
            }
            if let self {
                await self.handleTransportClosed()
            }
        }
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        readerTask?.cancel()
        for continuation in pendingRequests.values {
            continuation.resume(throwing: ACPTransportError.transportClosed)
        }
        pendingRequests.removeAll()
        await transport.close()
    }

    public func onRequest(
        method: String,
        handler: @escaping @Sendable (ACPJSONRPCRequest) async throws -> ACPJSONRPCResponse
    ) {
        requestHandlers[method] = handler
    }

    public func onNotification(
        method: String,
        handler: @escaping @Sendable (ACPJSONRPCNotification) async -> Void
    ) {
        notificationHandlers[method, default: []].append(handler)
    }

    public func sendNotification<T: Encodable>(method: String, params: T) async throws {
        guard !isClosed else { throw ACPTransportError.transportClosed }
        let paramsData = try JSONEncoder().encode(params)
        let paramsValue = try JSONDecoder().decode(ACPValue.self, from: paramsData)
        let notification = ACPJSONRPCNotification(method: method, params: paramsValue)
        try await transport.send(.notification(notification))
    }

    /// Sends one request and awaits its response.
    ///
    /// - Parameter didSend: Called once with the request's ID after the
    ///   transport has accepted the request and before the response is awaited.
    ///   A caller that may cancel the request (`$/cancel_request`) needs the ID,
    ///   and must not cancel a request the Runtime has not been sent.
    public func sendRequest<Req: Encodable, Resp: Decodable>(
        method: String,
        params: Req,
        responseType: Resp.Type = Resp.self,
        timeoutSeconds: Double? = nil,
        didSend: (@Sendable (ACPRequestId) async -> Void)? = nil
    ) async throws -> Resp {
        guard !isClosed else { throw ACPTransportError.transportClosed }
        let reqID = nextRequestID
        nextRequestID += 1
        let strID = String(reqID)

        let paramsData = try JSONEncoder().encode(params)
        let paramsValue = try JSONDecoder().decode(ACPValue.self, from: paramsData)
        let request = ACPJSONRPCRequest(id: .int(Int(reqID)), method: method, params: paramsValue)

        let effectiveTimeout = timeoutSeconds ?? defaultTimeoutSeconds

        let response: ACPJSONRPCResponse = try await withThrowingTaskGroup(of: ACPJSONRPCResponse.self) { [self] group in
            group.addTask { [self] in
                try await withCheckedThrowingContinuation { continuation in
                    Task { [self] in
                        await self.registerPendingRequest(id: strID, continuation: continuation)
                        do {
                            try await self.transport.send(.request(request))
                            await didSend?(request.id)
                        } catch {
                            await self.cancelPendingRequest(id: strID, error: error)
                        }
                    }
                }
            }
            if effectiveTimeout > 0 {
                group.addTask { [self] in
                    try await Task.sleep(nanoseconds: UInt64(effectiveTimeout * 1_000_000_000))
                    await self.cancelPendingRequest(id: strID, error: ACPTransportError.timeout)
                    throw ACPTransportError.timeout
                }
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }

        if let error = response.error {
            throw ACPError.custom(code: error.code, message: error.message, data: error.data)
        }

        if Resp.self == ACPEmptyResponse.self {
            return ACPEmptyResponse() as! Resp
        }

        guard let result = response.result else {
            throw ACPError.internalError("Missing result in response for method '\(method)'")
        }

        let resultData = try JSONEncoder().encode(result)
        return try JSONDecoder().decode(Resp.self, from: resultData)
    }

    private func registerPendingRequest(id: String, continuation: CheckedContinuation<ACPJSONRPCResponse, any Error>) {
        pendingRequests[id] = continuation
    }

    private func cancelPendingRequest(id: String, error: any Error) {
        pendingRequests.removeValue(forKey: id)?.resume(throwing: error)
    }

    /// Stops waiting for a sent request: its caller receives `error`, and a
    /// response that arrives later is ignored.
    package func abandonRequest(id: ACPRequestId, error: any Error) {
        guard let key = id.stringValue else { return }
        cancelPendingRequest(id: key, error: error)
    }

    public func request<Req: Encodable, Resp: Decodable>(
        method: String,
        params: Req,
        responseType: Resp.Type = Resp.self,
        timeoutSeconds: Double? = nil,
        didSend: (@Sendable (ACPRequestId) async -> Void)? = nil
    ) async throws -> Resp {
        try await sendRequest(
            method: method,
            params: params,
            responseType: responseType,
            timeoutSeconds: timeoutSeconds,
            didSend: didSend
        )
    }

    // MARK: - Convenience Operations

    public func initialize(request: ACPInitializeRequest) async throws -> ACPInitializeResponse {
        try await self.request(method: ACPv2Protocol.AgentMethod.initialize, params: request, responseType: ACPInitializeResponse.self)
    }

    public func createSession(request: ACPNewSessionRequest) async throws -> ACPNewSessionResponse {
        try await self.request(method: ACPv2Protocol.AgentMethod.sessionNew, params: request, responseType: ACPNewSessionResponse.self)
    }

    public func resumeSession(request: ACPResumeSessionRequest) async throws -> ACPResumeSessionResponse {
        try await self.request(method: ACPv2Protocol.AgentMethod.sessionResume, params: request, responseType: ACPResumeSessionResponse.self)
    }

    public func closeSession(request: ACPCloseSessionRequest) async throws -> ACPCloseSessionResponse {
        try await self.request(method: ACPv2Protocol.AgentMethod.sessionClose, params: request, responseType: ACPCloseSessionResponse.self)
    }

    public func listSessions(request: ACPListSessionsRequest = ACPListSessionsRequest()) async throws -> ACPListSessionsResponse {
        try await self.request(method: ACPv2Protocol.AgentMethod.sessionList, params: request, responseType: ACPListSessionsResponse.self)
    }

    public func prompt(
        request: ACPPromptRequest,
        timeoutSeconds: Double? = nil,
        didSend: (@Sendable (ACPRequestId) async -> Void)? = nil
    ) async throws -> ACPPromptResponse {
        try await self.request(
            method: ACPv2Protocol.AgentMethod.sessionPrompt,
            params: request,
            responseType: ACPPromptResponse.self,
            timeoutSeconds: timeoutSeconds,
            didSend: didSend
        )
    }

    public func cancelSession(sessionId: String) async throws {
        try await self.sendNotification(method: ACPv2Protocol.AgentMethod.sessionCancel, params: ACPCancelSessionNotification(sessionId: sessionId))
    }

    public func cancelRequest(requestId: ACPRequestId) async throws {
        try await self.sendNotification(method: ACPv2Protocol.ProtocolMethod.cancelRequest, params: ACPCancelRequestNotification(requestId: requestId))
    }

    // MARK: - Message Dispatch

    private func handleIncomingMessage(_ message: ACPJSONRPCMessage) async {
        switch message {
        case let .response(resp):
            guard let strID = resp.id.stringValue, let continuation = pendingRequests.removeValue(forKey: strID) else {
                return
            }
            continuation.resume(returning: resp)

        case let .notification(notif):
            if let handlers = notificationHandlers[notif.method] {
                for handler in handlers {
                    await handler(notif)
                }
            }

        case let .request(req):
            if let handler = requestHandlers[req.method] {
                do {
                    let response = try await handler(req)
                    try await transport.send(.response(response))
                } catch {
                    let err = (error as? ACPError)?.toJSONRPCError() ?? ACPJSONRPCError(code: ACPv2Protocol.ErrorCode.internalError, message: "\(error)")
                    try? await transport.send(.response(ACPJSONRPCResponse(id: req.id, error: err)))
                }
            } else {
                let notFound = ACPJSONRPCError(code: ACPv2Protocol.ErrorCode.methodNotFound, message: "Method not found: \(req.method)")
                try? await transport.send(.response(ACPJSONRPCResponse(id: req.id, error: notFound)))
            }
        }
    }

    private func handleTransportClosed() {
        for continuation in pendingRequests.values {
            continuation.resume(throwing: ACPTransportError.transportClosed)
        }
        pendingRequests.removeAll()
    }
}
