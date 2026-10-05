// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A private, unauthenticated Mosquitto instance the test owns end to end.
///
/// A transport-boundary test must fault the broker on demand, so it cannot use
/// the shared deterministic broker. This launches the container's own
/// `mosquitto` binary on an ephemeral port with an anonymous listener.
///
/// `make()` returns `nil` when no `mosquitto` binary is present; the container
/// image ships one, so the container gate always runs the calling test.
final class PrivateMosquitto {
    /// The anonymous listener port.
    let port: Int

    private let binary: URL
    private let directory: URL
    private let configURL: URL
    private var process: Process?

    /// `socket(AF_INET, _, 0)`'s type argument differs by platform: Glibc exposes
    /// `SOCK_STREAM` as `__socket_type`, Darwin as `Int32`.
    #if canImport(Darwin)
    private static let streamSocketType = SOCK_STREAM
    #else
    private static let streamSocketType = Int32(SOCK_STREAM.rawValue)
    #endif

    /// Starts a private broker, or returns `nil` when it cannot be started.
    static func make() -> PrivateMosquitto? {
        guard let binary = locateBinary() else { return nil }
        for _ in 0..<5 {
            guard let port = ephemeralPort() else { return nil }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("gnostic-mosquitto-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let configURL = directory.appendingPathComponent("mosquitto.conf")
            let config = """
            listener \(port) 127.0.0.1
            allow_anonymous true
            persistence false
            pid_file \(directory.appendingPathComponent("mosquitto.pid").path)
            log_dest file \(directory.appendingPathComponent("mosquitto.log").path)
            """
            guard (try? config.write(to: configURL, atomically: true, encoding: .utf8)) != nil else { continue }

            let broker = PrivateMosquitto(port: port, binary: binary, directory: directory, configURL: configURL)
            if broker.start() { return broker }
            broker.stop()
        }
        return nil
    }

    private init(port: Int, binary: URL, directory: URL, configURL: URL) {
        self.port = port
        self.binary = binary
        self.directory = directory
        self.configURL = configURL
    }

    /// Launches the broker and waits until its port accepts connections.
    ///
    /// - Returns: Whether the broker became ready before the bound.
    @discardableResult
    func start() -> Bool {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["-c", configURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        self.process = process

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if !process.isRunning { return false }
            if Self.canConnect(host: "127.0.0.1", port: port) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    /// Terminates the broker and waits for it to exit.
    func stop() {
        guard let process else { return }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        self.process = nil
    }

    private static func locateBinary() -> URL? {
        let candidates = [
            "/usr/sbin/mosquitto",
            "/opt/homebrew/sbin/mosquitto",
            "/usr/local/sbin/mosquitto",
            "/usr/bin/mosquitto",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }

    /// Binds a socket to port 0 and reads the assigned port back.
    private static func ephemeralPort() -> Int? {
        let descriptor = socket(AF_INET, streamSocketType, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func canConnect(host: String, port: Int) -> Bool {
        let descriptor = socket(AF_INET, streamSocketType, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr(host)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connected == 0
    }
}
