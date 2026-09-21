// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Launches the Node-based Letta HTTP fixture server for a test and exposes its
/// loopback base URL. The fixture needs no credential and no network.
final class FixtureHTTPServerProcess: @unchecked Sendable {
    let baseURL: URL
    private let process: Process

    init(timeout: TimeInterval = 15) throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Fixtures/LettaHTTPServer/letta-fixture-server.mjs")
            .standardizedFileURL
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw FixtureHTTPServerError.scriptMissing(script.path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", script.path, "--port", "0"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        self.process = process

        let box = PortBox()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            guard let line = text.split(separator: "\n").first,
                  let port = UInt16(line.trimmingCharacters(in: .whitespaces)) else { return }
            box.set(port)
            handle.readabilityHandler = nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while box.get() == nil && Date() < deadline && process.isRunning {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard let port = box.get() else {
            process.terminate()
            throw FixtureHTTPServerError.portUnavailable
        }
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }
}

enum FixtureHTTPServerError: Error {
    case scriptMissing(String)
    case portUnavailable
}

private final class PortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt16?

    func set(_ port: UInt16) {
        lock.lock()
        value = port
        lock.unlock()
    }

    func get() -> UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
