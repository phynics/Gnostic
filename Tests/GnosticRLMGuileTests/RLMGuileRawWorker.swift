// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticRLM
import GnosticRLMGuile

/// A raw, unvalidated framed client for the Guile worker.
///
/// It deliberately bypasses `RLMGuileWorkerSession` so tests can prove that the
/// sandbox itself, not only the parent validator, rejects dangerous forms.
enum RLMGuileRawWorkerError: Error {
    case unavailable
    case spawnFailed(String)
    case closed
}

final class RLMGuileRawWorker {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let errorOutput: FileHandle
    let runID: String

    init(runID: String) throws {
        guard let guile = RLMGuileTestSupport.guilePath else {
            throw RLMGuileRawWorkerError.unavailable
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: guile)
        process.arguments = [
            "--no-auto-compile",
            "-s", RLMGuileTestSupport.workerScriptPath,
            "--max-address-space", "268435456",
            "--max-cpu", "10",
        ]
        process.environment = RLMGuileWorkerConfiguration.scrubbedEnvironment
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw RLMGuileRawWorkerError.spawnFailed("\(error)")
        }
        self.process = process
        self.input = inputPipe.fileHandleForWriting
        self.output = outputPipe.fileHandleForReading
        self.errorOutput = errorPipe.fileHandleForReading
        self.runID = runID
    }

    func send(_ frame: RLMSchemeWorkerFrame) throws {
        let bytes = try RLMSchemeWorkerCodec.encode(frame)
        try input.write(contentsOf: Data(bytes))
    }

    func receive() throws -> RLMSchemeWorkerFrame {
        try readFrame()
    }

    @discardableResult
    func initialize() throws -> RLMSchemeWorkerFrame {
        try send(.initialize(RLMSchemeInitialize(
            runID: runID,
            profile: RLMSchemeProfile.name,
            maxHeapBytes: 64 * 1_024 * 1_024,
            maxOutputBytes: 256 * 1_024,
            timeLimitSeconds: 5,
            allocationLimitBytes: 32 * 1_024 * 1_024
        )))
        return try receive()
    }

    func evaluate(_ source: String, cellID: Int) throws -> RLMSchemeWorkerFrame {
        try send(.evaluate(RLMSchemeEvaluate(runID: runID, cellID: cellID, source: source)))
        while true {
            let frame = try receive()
            if case let .hostCall(call) = frame {
                try send(.hostError(RLMSchemeHostError(
                    runID: runID,
                    callID: call.callID,
                    message: "host calls are not serviced"
                )))
                continue
            }
            return frame
        }
    }

    func shutdown() {
        try? send(.shutdown(runID: runID))
        try? input.close()
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        try? output.close()
        try? errorOutput.close()
    }

    private func readExactly(_ handle: FileHandle, count: Int) throws -> Data? {
        var data = Data()
        while data.count < count {
            guard let chunk = try? handle.read(upToCount: count - data.count), !chunk.isEmpty else {
                return nil
            }
            data.append(chunk)
        }
        return data
    }

    private func readFrame() throws -> RLMSchemeWorkerFrame {
        guard let header = try readExactly(output, count: 4), header.count == 4 else {
            throw RLMGuileRawWorkerError.closed
        }
        let bytes = [UInt8](header)
        let length = (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
        guard let payload = try readExactly(output, count: Int(length)) else {
            throw RLMGuileRawWorkerError.closed
        }
        return try RLMSchemeWorkerCodec.decode([UInt8](payload))
    }
}
