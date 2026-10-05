// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation
import GnosticCore

/// Drives scripted Turns against a running `gnostic serve` for the soak target
/// (GNO-PLAT-062, #454). It composes nothing: it is a consumer over the public
/// client API, exactly as an external client would be.
@main
struct GnosticSoakDriver: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gnostic-soak-driver",
        abstract: "Run scripted Turns against a serve node for the soak target."
    )

    @Option(name: .long, help: "MQTT broker host.")
    var host = "127.0.0.1"

    @Option(name: .long, help: "MQTT broker port.")
    var port = 1883

    @Option(name: .long, help: "MQTT namespace.")
    var namespace: String

    @Option(name: .long, help: "Timeline UUID to address.")
    var timeline: String

    @Option(name: .long, help: "Number of Turns to run.")
    var turns = 100

    @Option(name: .customLong("interval-ms"), help: "Delay between Turns in milliseconds.")
    var intervalMilliseconds = 0

    @Option(name: .customLong("turn-timeout"), help: "Seconds to wait for one Turn.")
    var turnTimeoutSeconds = 30

    @MainActor
    func run() async throws {
        guard let timelineID = UUID(uuidString: timeline) else {
            throw ValidationError("--timeline must be a Timeline UUID.")
        }
        let session = try GnosticConsumerSession(
            broker: .init(host: host, port: port, namespace: namespace),
            identityName: "gnostic-soak-\(UUID().uuidString.lowercased())"
        )
        try await session.start()
        try await session.discover()
        let client = try session.turnClient(
            timeout: .seconds(turnTimeoutSeconds),
            promptTimeout: .seconds(turnTimeoutSeconds)
        )

        if turns > 0 {
            for index in 1...turns {
                let result = try await client.run(
                    message: "soak turn \(index)",
                    timelineID: timelineID,
                    clientTurnID: "soak-\(index)"
                )
                print("soak turn \(index) ok chars=\(result.text.count) replayed=\(result.replayed)")
                if intervalMilliseconds > 0 {
                    try await Task.sleep(for: .milliseconds(intervalMilliseconds))
                }
            }
        }
        await session.stop()
    }
}
