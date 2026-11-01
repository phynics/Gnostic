// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation
import GnosticClient
import GnosticProtocol

/// Attaches a discovered Workspace to a Timeline for the T4 acceptance runbook.
///
/// `gnostic` has no command that attaches a Workspace to a live Timeline, and a
/// Timeline that `gnostic acp` creates is not in any manifest. This executable
/// is a consumer over the public client API, like an external client. It makes
/// the same `workspace.attach` call that the two-Node integration test makes.
@main
struct GnosticWorkspaceAttach: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gnostic-workspace-attach",
        abstract: "Attach a discovered Workspace to a Timeline over the Gnostic wire."
    )

    @Option(name: .long, help: "MQTT broker host.")
    var host = "127.0.0.1"

    @Option(name: .long, help: "MQTT broker port.")
    var port = 1883

    @Option(name: .long, help: "MQTT namespace.")
    var namespace: String

    @Option(name: .long, help: "Timeline UUID to attach to.")
    var timeline: String

    @Option(name: .long, help: "Workspace UUID to attach.")
    var workspace: String

    @Option(name: .customLong("wait-seconds"), help: "Seconds to wait for both objects to be advertised.")
    var waitSeconds = 20

    @MainActor
    func run() async throws {
        guard let timelineID = UUID(uuidString: timeline) else {
            throw ValidationError("--timeline must be a Timeline UUID.")
        }
        guard let workspaceID = UUID(uuidString: workspace) else {
            throw ValidationError("--workspace must be a Workspace UUID.")
        }
        let session = try GnosticConsumerSession(
            broker: .init(host: host, port: port, namespace: namespace),
            identityName: "gnostic-workspace-attach-\(UUID().uuidString.lowercased())"
        )
        try await session.start()
        do {
            var timelineProviderID: String?
            let deadline = ContinuousClock.now.advanced(by: .seconds(waitSeconds))
            while timelineProviderID == nil, ContinuousClock.now < deadline {
                try await session.discover(timeout: .milliseconds(500))
                let objects = await session.networkObjects()
                let workspaceAdvertised = objects.contains {
                    $0.objectType == GnosticObjectType.workspace && $0.objectID == workspaceID
                }
                if workspaceAdvertised {
                    timelineProviderID = objects.first {
                        $0.objectType == GnosticObjectType.timeline && $0.objectID == timelineID
                    }?.providerID
                }
            }
            guard let timelineProviderID else {
                throw ValidationError("The Workspace and the Timeline were not both advertised within \(waitSeconds) seconds.")
            }
            let client = try session.workspaceClient(timeout: .seconds(10))
            try await client.attach(
                workspaceID: workspaceID,
                to: timelineID,
                approved: true,
                providerID: timelineProviderID
            )
            let status = await client.effectiveStatus(workspaceID: workspaceID)
            print("attached workspace \(workspaceID.uuidString.lowercased()) to timeline \(timelineID.uuidString.lowercased()) (effective status: \(status.rawValue))")
        } catch {
            await session.stop()
            throw error
        }
        await session.stop()
    }
}
