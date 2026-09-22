// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticRLM

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// One disposable Guile worker process with a run-local Scheme environment.
///
/// The session owns process supervision, the framed protocol, parent-side cell
/// validation, host-call servicing, and the cancellation and wall-time fences.
/// Process death is the authoritative termination boundary.
#if os(macOS) || os(Linux)
public actor RLMGuileWorkerSession {
    private let configuration: RLMGuileWorkerConfiguration
    private let host: any RLMGuileHost
    private let cancellation: RLMCancellationToken
    private let fence: RLMRunFence

    private var process: Process?
    private var inputHandle: FileHandle?
    private var continuation: AsyncStream<RLMSchemeWorkerFrame>.Continuation?
    private var iteratorBox: IteratorBox?
    private var isEvaluating = false
    private let readerFailure = FailureBox()
    private let stderrBuffer = StderrBox()
    private let readerGroup = ReaderGroup()

    private var nextCellID = 1
    private var hasStarted = false
    private var definitions: Set<String> = []

    public private(set) var ready: RLMSchemeReady?

    public init(
        configuration: RLMGuileWorkerConfiguration,
        host: any RLMGuileHost,
        cancellation: RLMCancellationToken = RLMCancellationToken()
    ) {
        self.configuration = configuration
        self.host = host
        self.cancellation = cancellation
        self.fence = RLMRunFence()
    }

    public var isRunning: Bool {
        process?.isRunning ?? false
    }

    /// The supervised child process identifier while the worker is running.
    /// Benchmark and diagnostics code may use it for host-owned resource
    /// sampling; the worker protocol never receives this value.
    public var processIdentifier: Int32? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    public var stderrTail: String {
        String(decoding: stderrBuffer.snapshot(), as: UTF8.self)
    }

    /// Spawns the worker and completes the initialize handshake.
    public func start() async throws {
        guard !hasStarted else { return }
        hasStarted = true

        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: configuration.executablePath) else {
            throw RLMGuileWorkerError.executableMissing(configuration.executablePath)
        }
        guard fileManager.fileExists(atPath: configuration.workerScriptPath) else {
            throw RLMGuileWorkerError.workerScriptMissing(configuration.workerScriptPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.executablePath)
        process.arguments = [
            "--no-auto-compile",
            "-s", configuration.workerScriptPath,
            "--max-address-space", String(configuration.maxAddressSpaceBytes),
            "--max-cpu", String(configuration.maxCPUSeconds),
        ]
        process.environment = configuration.environment

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw RLMGuileWorkerError.spawnFailed("\(error)")
        }

        self.process = process
        self.inputHandle = inputPipe.fileHandleForWriting

        let (stream, streamContinuation) = AsyncStream<RLMSchemeWorkerFrame>.makeStream()
        self.continuation = streamContinuation
        self.iteratorBox = IteratorBox(stream.makeAsyncIterator())
        Self.startReader(
            stdout: FileHandleBox(outputPipe.fileHandleForReading),
            stderr: FileHandleBox(errorPipe.fileHandleForReading),
            continuation: streamContinuation,
            failure: readerFailure,
            stderrBuffer: stderrBuffer,
            readerGroup: readerGroup,
            maxFrameBytes: configuration.maxOutputBytes
        )

        try send(.initialize(RLMSchemeInitialize(
            runID: configuration.runID,
            profile: configuration.profile,
            maxHeapBytes: configuration.maxHeapBytes,
            maxOutputBytes: configuration.maxOutputBytes,
            timeLimitSeconds: configuration.cellTimeLimitSeconds,
            allocationLimitBytes: configuration.cellAllocationLimitBytes
        )))

        let readyFrame = await nextFrame(deadline: configuration.startupDeadlineSeconds)
        guard case let .ready(frame)? = readyFrame else {
            terminate()
            throw RLMGuileWorkerError.initializationFailed("worker did not report ready")
        }
        guard frame.runID == configuration.runID else {
            terminate()
            throw RLMGuileWorkerError.initializationFailed("worker run identity mismatch")
        }
        ready = frame
    }

    /// Validates and evaluates one cell in the run-local environment.
    public func evaluate(source: String, cellID: Int? = nil) async -> RLMGuileEvaluationOutcome {
        guard hasStarted, process?.isRunning == true else {
            return .workerExited(workerExitCode())
        }
        guard !isEvaluating else {
            return .fenced
        }
        isEvaluating = true
        defer { isEvaluating = false }
        if cancellation.isCancelled {
            return .cancelled
        }
        let validation: RLMSchemeValidation
        do {
            validation = try RLMSchemeProfile.validate(
                source,
                limits: configuration.validationLimits,
                definitions: definitions
            )
        } catch {
            return .cellRejected("\(error)")
        }
        definitions.formUnion(validation.usage.userDefinitions)

        let id = cellID ?? nextCellID
        nextCellID = max(nextCellID, id + 1)
        let generation = fence.current

        do {
            try send(.evaluate(RLMSchemeEvaluate(
                runID: configuration.runID,
                cellID: id,
                source: source
            )))
        } catch {
            return .workerExited(workerExitCode())
        }

        let outcome = await withWallDeadline { await self.performEvaluation(cellID: id, generation: generation) }
        if cancellation.isCancelled {
            return .cancelled
        }
        if !fence.accepts(generation) {
            return .fenced
        }
        if case .timedOut = outcome {
            terminate()
        }
        if case .outputLimitReached = outcome {
            terminate()
        }
        if case .protocolViolation = outcome {
            terminate()
        }
        if case .hostResultRejected = outcome {
            terminate()
        }
        return outcome
    }

    /// Fences the run, cancels in-flight work, and destroys the worker.
    public func cancel() {
        fence.invalidate()
        cancellation.cancel()
        try? send(.cancel(runID: configuration.runID))
        terminate()
    }

    /// Sends a shutdown frame and waits for the bounded grace boundary.
    public func shutdown() async {
        if process?.isRunning == true {
            try? send(.shutdown(runID: configuration.runID))
            closeInput()
            let deadline = Date().addingTimeInterval(configuration.terminationGraceSeconds)
            while let process, process.isRunning, Date() < deadline {
                usleep(5_000)
            }
        }
        terminate()
    }

    private func performEvaluation(cellID: Int, generation: UInt64) async -> RLMGuileEvaluationOutcome {
        while true {
            if cancellation.isCancelled {
                return .cancelled
            }
            if !fence.accepts(generation) {
                return .fenced
            }
            guard let frame = await nextFrameInternal() else {
                return readerFailure.get() ?? .workerExited(workerExitCode())
            }
            switch frame {
            case let .hostCall(call):
                guard call.runID == configuration.runID else { continue }
                switch await service(call) {
                case let .value(value):
                    do {
                        try send(.hostResult(RLMSchemeHostResult(
                            runID: configuration.runID,
                            callID: call.callID,
                            value: value
                        )), maxFrameBytes: configuration.maxOutputBytes)
                    } catch {
                        return .hostResultRejected("\(error)")
                    }
                case let .failure(message):
                    do {
                        try send(.hostError(RLMSchemeHostError(
                            runID: configuration.runID,
                            callID: call.callID,
                            message: message
                        )), maxFrameBytes: configuration.maxOutputBytes)
                    } catch {
                        return .hostResultRejected("\(error)")
                    }
                case .cancelled:
                    return .cancelled
                }
            case let .evaluated(evaluated):
                guard evaluated.cellID == cellID else { continue }
                return .value(evaluated.value)
            case let .finished(finished):
                guard finished.runID == configuration.runID else { continue }
                return .finished(answer: finished.answer, evidenceIDs: finished.evidenceIDs)
            case let .failed(failure):
                guard failure.cellID == cellID else { continue }
                return .schemeFailed(failure.message)
            default:
                continue
            }
        }
    }

    private enum HostServiceResult {
        case value(RLMSExpression)
        case failure(String)
        case cancelled
    }

    private func service(_ call: RLMSchemeHostCall) async -> HostServiceResult {
        guard let operation = Self.operation(for: call) else {
            return .failure("unsupported host call '\(call.name)'")
        }
        if cancellation.isCancelled {
            return .cancelled
        }
        do {
            let observation = try await host.service(operation)
            if cancellation.isCancelled {
                return .cancelled
            }
            return .value(Self.wireValue(for: observation))
        } catch let failure as RLMFailure {
            return .failure(failure.description)
        } catch {
            return .failure("\(error)")
        }
    }

    static func operation(for call: RLMSchemeHostCall) -> RLMHostOperation? {
        switch call.name {
        case "corpus-search":
            guard call.arguments.count == 2,
                  case let .string(query) = call.arguments[0],
                  case let .integer(limit) = call.arguments[1] else { return nil }
            return .corpusSearch(query: query, limit: limit)

        case "corpus-read":
            guard call.arguments.count == 1, case let .string(chunkID) = call.arguments[0] else { return nil }
            return .corpusRead(chunkIDs: [chunkID])

        case "corpus-read-many":
            guard call.arguments.count == 1, case let .list(identifiers) = call.arguments[0] else { return nil }
            var chunkIDs: [String] = []
            for identifier in identifiers {
                guard case let .string(value) = identifier else { return nil }
                chunkIDs.append(value)
            }
            return .corpusRead(chunkIDs: chunkIDs)

        case "lm-query":
            guard let prompts = prompts(from: call.arguments, batched: false),
                  let tier = tier(from: call.arguments) else { return nil }
            return .leafQuery(prompts: prompts, tier: tier)

        case "lm-query-batched":
            guard let prompts = prompts(from: call.arguments, batched: true),
                  let tier = tier(from: call.arguments) else { return nil }
            return .leafQuery(prompts: prompts, tier: tier)

        case "progress":
            guard call.arguments.count == 1, case let .string(message) = call.arguments[0] else { return nil }
            return .progress(message)

        default:
            return nil
        }
    }

    private static func prompts(from arguments: [RLMSExpression], batched: Bool) -> [String]? {
        guard let first = arguments.first else { return nil }
        if batched {
            guard case let .list(values) = first else { return nil }
            var prompts: [String] = []
            for value in values {
                guard case let .string(text) = value else { return nil }
                prompts.append(text)
            }
            return prompts
        }
        guard case let .string(text) = first else { return nil }
        return [text]
    }

    private static func tier(from arguments: [RLMSExpression]) -> RLMLeafModelTier? {
        guard (1...2).contains(arguments.count) else { return nil }
        guard arguments.count == 2 else { return .fast }
        guard case let .symbol(name) = arguments[1], let tier = RLMLeafModelTier(rawValue: name) else {
            return nil
        }
        return tier
    }

    private static func wireValue(for observation: RLMHostObservation) -> RLMSExpression {
        switch observation {
        case let .corpusSearch(hits, _):
            return .list(hits.map { hit in
                .list([
                    .string(hit.chunkID),
                    .string(hit.path),
                    .integer(hit.startLine),
                    .integer(hit.endLine),
                    .string(hit.preview),
                ])
            })
        case let .corpusRead(chunks, _):
            return .list(chunks.map { chunk in
                .list([
                    .string(chunk.id),
                    .string(chunk.path),
                    .integer(chunk.startLine),
                    .integer(chunk.endLine),
                    .string(chunk.content),
                ])
            })
        case let .leaf(responses, _):
            return .list(responses.map { .string($0) })
        case .progress:
            return .boolean(true)
        }
    }

    private func withWallDeadline(
        _ operation: @escaping @Sendable () async -> RLMGuileEvaluationOutcome
    ) async -> RLMGuileEvaluationOutcome {
        await withTaskGroup(of: RLMGuileEvaluationOutcome.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(self.configuration.wallDeadlineSeconds))
                return .timedOut
            }
            let first = await group.next() ?? .workerExited(-1)
            group.cancelAll()
            return first
        }
    }

    private func nextFrame(deadline: Double) async -> RLMSchemeWorkerFrame? {
        await withTaskGroup(of: RLMSchemeWorkerFrame?.self) { group in
            group.addTask { await self.nextFrameInternal() }
            group.addTask {
                try? await Task.sleep(for: .seconds(deadline))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func nextFrameInternal() async -> RLMSchemeWorkerFrame? {
        guard let box = iteratorBox else { return nil }
        return await box.next()
    }

    private func send(_ frame: RLMSchemeWorkerFrame) throws {
        try send(frame, maxFrameBytes: RLMSchemeWorkerCodec.maxFrameBytes)
    }

    private func send(_ frame: RLMSchemeWorkerFrame, maxFrameBytes limit: Int) throws {
        guard let inputHandle else {
            throw RLMGuileWorkerError.alreadyShutDown
        }
        let bytes = try RLMSchemeWorkerCodec.encode(frame, maxFrameBytes: limit)
        try RLMGuileProcessSignals.withoutBrokenPipeSignal {
            try inputHandle.write(contentsOf: Data(bytes))
        }
    }

    private func closeInput() {
        try? inputHandle?.close()
        inputHandle = nil
    }

    private func workerExitCode() -> Int32 {
        guard let process, !process.isRunning else { return -1 }
        return process.terminationStatus
    }

    private func terminate() {
        if let process, process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(configuration.terminationGraceSeconds)
            while process.isRunning, Date() < deadline {
                usleep(5_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        closeInput()
        continuation?.finish()
        _ = readerGroup.group.wait(timeout: .now() + configuration.terminationGraceSeconds)
        continuation = nil
        iteratorBox = nil
        process = nil
    }

    private struct FileHandleBox: @unchecked Sendable { // SAFETY: each box is read by exactly one dedicated reader thread and Foundation serializes access to a single FileHandle.
        let handle: FileHandle

        init(_ handle: FileHandle) {
            self.handle = handle
        }
    }

    private final class IteratorBox: @unchecked Sendable { // SAFETY: the owning actor is the only consumer; the unchecked conformance carries the iterator across the async next() boundary.
        private var iterator: AsyncStream<RLMSchemeWorkerFrame>.Iterator

        init(_ iterator: AsyncStream<RLMSchemeWorkerFrame>.Iterator) {
            self.iterator = iterator
        }

        func next() async -> RLMSchemeWorkerFrame? {
            await iterator.next()
        }
    }

    private final class FailureBox: @unchecked Sendable { // SAFETY: the NSLock serializes the single reader-thread write against actor reads.
        private let lock = NSLock()
        private var value: RLMGuileEvaluationOutcome?

        func set(_ outcome: RLMGuileEvaluationOutcome) {
            lock.lock()
            value = outcome
            lock.unlock()
        }

        func get() -> RLMGuileEvaluationOutcome? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class StderrBox: @unchecked Sendable { // SAFETY: the NSLock serializes the reader-thread append against actor reads.
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            let remaining = 8_192 - data.count
            if remaining > 0 {
                data.append(chunk.prefix(remaining))
            }
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    private final class ReaderGroup: @unchecked Sendable { // SAFETY: DispatchGroup is thread-safe; it joins the two reader threads before the session releases state.
        let group = DispatchGroup()
    }

    private static func startReader(
        stdout: FileHandleBox,
        stderr: FileHandleBox,
        continuation: AsyncStream<RLMSchemeWorkerFrame>.Continuation,
        failure: FailureBox,
        stderrBuffer: StderrBox,
        readerGroup: ReaderGroup,
        maxFrameBytes: Int
    ) {
        readerGroup.group.enter()
        Thread.detachNewThread {
            defer {
                continuation.finish()
                readerGroup.group.leave()
            }
            while true {
                guard let header = Self.readExactly(stdout.handle, count: 4), header.count == 4 else { return }
                let bytes = [UInt8](header)
                let length = (UInt32(bytes[0]) << 24)
                    | (UInt32(bytes[1]) << 16)
                    | (UInt32(bytes[2]) << 8)
                    | UInt32(bytes[3])
                guard length <= UInt32(maxFrameBytes) else {
                    failure.set(.outputLimitReached)
                    return
                }
                guard let payload = Self.readExactly(stdout.handle, count: Int(length)) else { return }
                guard let frame = try? RLMSchemeWorkerCodec.decode([UInt8](payload)) else {
                    failure.set(.protocolViolation("undecodable worker frame: \(String(decoding: payload, as: UTF8.self))"))
                    return
                }
                continuation.yield(frame)
            }
        }
        readerGroup.group.enter()
        Thread.detachNewThread {
            defer { readerGroup.group.leave() }
            while true {
                guard let chunk = try? stderr.handle.read(upToCount: 4_096), !chunk.isEmpty else { return }
                stderrBuffer.append(chunk)
            }
        }
    }

    private static func readExactly(_ handle: FileHandle, count: Int) -> Data? {
        var data = Data()
        while data.count < count {
            guard let chunk = try? handle.read(upToCount: count - data.count), !chunk.isEmpty else {
                return nil
            }
            data.append(chunk)
        }
        return data
    }
}
#else
public actor RLMGuileWorkerSession {
    public init(
        configuration: RLMGuileWorkerConfiguration,
        host: any RLMGuileHost,
        cancellation: RLMCancellationToken = RLMCancellationToken()
    ) {}

    public var isRunning: Bool { false }

    public var processIdentifier: Int32? { nil }

    public var stderrTail: String { "" }

    public private(set) var ready: RLMSchemeReady?

    public func start() async throws {
        throw RLMGuileWorkerError.unsupportedPlatform
    }

    public func evaluate(source: String, cellID: Int? = nil) async -> RLMGuileEvaluationOutcome {
        .unsupportedPlatform
    }

    public func cancel() {}

    public func shutdown() async {}
}
#endif
