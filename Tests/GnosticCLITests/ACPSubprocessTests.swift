// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore
import GnosticProtocol
import Testing

@testable import GnosticACPFrontend
@testable import GnosticCLI

/// Clean ACP smoke coverage.
///
/// The suite keeps the filter name used by `make acp-smoke`. It exercises the
/// shipped `gnostic acp` command against broker advertisements from Runtime
/// fixture providers.
@Suite("ACP subprocess", .serialized)
struct ACPSubprocessTests {
    @Test("ACP selection uses Runtime when its ID collides with a legacy Ascendant projection")
    @MainActor
    func selectsCanonicalRuntimeAdvertisement() throws {
        let id = UUID(uuidString: "e51d0000-0000-4000-8000-000000000002")!
        let nodeID = UUID(uuidString: "e51d0000-0000-4000-8000-000000000001")!
        let legacyProjection = NetworkCatalogEntry(
            objectID: id,
            objectType: GnosticObjectType.ascendant,
            protocolMajor: GnosticProtocol.currentMajor,
            providerID: "provider",
            name: "Legacy projection",
            knownProperties: [:],
            dynamicProperties: [:],
            workspace: nil
        )
        let runtime = NetworkCatalogEntry(
            objectID: id,
            objectType: GnosticObjectType.runtimeInstance,
            protocolMajor: GnosticProtocol.currentMajor,
            providerID: "provider",
            name: "ACP fixture Runtime",
            knownProperties: ["nodeID": .string(nodeID.uuidString)],
            dynamicProperties: [:],
            workspace: nil
        )

        let candidates = RemoteTurnClient.discoveredRuntimes(from: [legacyProjection, runtime])
        let selected = try RemoteTurnClient.selectCandidate(from: candidates, id: id)
        #expect(candidates.count == 1)
        #expect(selected.runtimeID == id)
        #expect(selected.name == "ACP fixture Runtime")
        #expect(selected.nodeID == nodeID)
        let profiles = ACPCommand.profiles(
            from: [legacyProjection, runtime],
            host: "127.0.0.1",
            port: 1883,
            namespace: "fixture"
        )
        #expect(profiles.count == 1)
        #expect(profiles[0].args.contains("--runtime"))
        #expect(!profiles[0].args.contains("--ascendant"))
    }

    @Test("explicit Node selection requires a known matching Node ID")
    @MainActor
    func explicitNodeSelectionRequiresKnownMatch() throws {
        let runtimeID = UUID(uuidString: "e51d0000-0000-4000-8000-000000000002")!
        let requestedNodeID = UUID(uuidString: "e51d0000-0000-4000-8000-000000000001")!
        let otherNodeID = UUID(uuidString: "e51d0000-0000-4000-8000-000000000003")!
        let withoutNode = RemoteTurnClient.DiscoveredRuntimeInstance(
            runtimeID: runtimeID,
            name: "Runtime without Node metadata",
            providerID: "provider-a"
        )
        let matchingNode = RemoteTurnClient.DiscoveredRuntimeInstance(
            runtimeID: runtimeID,
            name: "Runtime on requested Node",
            providerID: "provider-a",
            nodeID: requestedNodeID
        )
        let wrongNode = RemoteTurnClient.DiscoveredRuntimeInstance(
            runtimeID: runtimeID,
            name: "Runtime on another Node",
            providerID: "provider-b",
            nodeID: otherNodeID
        )

        #expect(selectionErrorCode(from: [withoutNode]) == "nodeUnavailable")
        #expect(try RemoteTurnClient.selectCandidate(from: [matchingNode], id: runtimeID, nodeID: requestedNodeID) == matchingNode)
        #expect(selectionErrorCode(from: [wrongNode]) == "nodeUnavailable")

        // Provider-only profiles remain valid for Runtime advertisements without Node metadata.
        #expect(try RemoteTurnClient.selectCandidate(from: [withoutNode], providerID: "provider-a") == withoutNode)

        func selectionErrorCode(from candidates: [RemoteTurnClient.DiscoveredRuntimeInstance]) -> String? {
            do {
                _ = try RemoteTurnClient.selectCandidate(from: candidates, id: runtimeID, nodeID: requestedNodeID)
                return nil
            } catch let error as RemoteTurnClientError {
                return error.gnosticCode
            } catch {
                return nil
            }
        }
    }

    @Test("final discovery failure formatting bounds and sanitizes the entire response")
    @MainActor
    func discoveryFailureFormattingIsBounded() {
        let selector = "provider\n\u{001B}" + String(repeating: "p", count: 4_000)
        let error = RemoteTurnClientError.providerUnavailable(selector)
        let formatted = RemoteTurnClient.discoveryFailureDescription(
            error: error,
            diagnostics: "catalog\r\n" + String(repeating: "d", count: 4_000)
        )

        #expect(formatted.count <= 1_320)
        #expect(!formatted.contains("\n"))
        #expect(!formatted.contains("\r"))
        #expect(!formatted.contains("\u{001B}"))
        #expect(formatted.contains("Provider provider"))
        #expect(formatted.contains("Discovery details: catalog"))
        #expect(formatted.contains("…"))
    }

    @Test("ACP discovery diagnostics bound and sanitize catalog details")
    @MainActor
    func discoveryDiagnosticsAreBounded() {
        let entries = (0..<24).map { index in
            NetworkCatalogEntry(
                objectID: UUID(),
                objectType: GnosticObjectType.runtimeInstance,
                protocolMajor: GnosticProtocol.currentMajor,
                providerID: "provider\n\u{001B}" + String(repeating: "x", count: 300),
                name: "Runtime \(index)",
                knownProperties: ["rawCapabilities": .object(Dictionary(uniqueKeysWithValues: (0..<2_000).map { ("cap-\($0)", NetworkDynamicValue.bool(true)) }))],
                dynamicProperties: [:],
                workspace: nil
            )
        }
        let summary = RemoteTurnClient.discoverySummary(entries)
        #expect(summary.count <= 1_024)
        #expect(!summary.contains("\n"))
        #expect(!summary.contains("\u{001B}"))
        #expect(summary.contains("truncated=true"))
        #expect(summary.contains("capabilityCount=999+"))
    }

    @Test(
        "profile discovery emits deterministic source profiles",
        .timeLimit(.minutes(1)),
        .enabled(if: ProcessInfo.processInfo.environment["GNOSTIC_ACP_BINARY"] != nil, "GNOSTIC_ACP_BINARY is not set")
    )
    @MainActor
    func discoversProfiles() async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["GNOSTIC_ACP_BINARY"])
        let namespace = "acp-profiles-\(UUID().uuidString.lowercased())"
        let sharedRuntimeID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        let uniqueRuntimeID = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
        let firstNodeID = UUID(uuidString: "30000000-0000-4000-8000-000000000001")!
        let secondNodeID = UUID(uuidString: "40000000-0000-4000-8000-000000000001")!
        let firstProvider = try makeACPProfileProvider(
            name: "ACP profile provider A",
            namespace: namespace,
            runtimes: [
                (sharedRuntimeID, firstNodeID, "Shared Runtime A"),
                (uniqueRuntimeID, firstNodeID, "Unique Runtime"),
            ]
        )
        let secondProvider = try makeACPProfileProvider(
            name: "ACP profile provider B",
            namespace: namespace,
            runtimes: [(sharedRuntimeID, secondNodeID, "Shared Runtime B")]
        )
        defer {
            firstProvider.stop()
            secondProvider.stop()
        }
        try await startACPProfileProvider(firstProvider)
        try await startACPProfileProvider(secondProvider)

        let profiles = try await readProfiles(binary: binary, namespace: namespace)
        let refreshedProfiles = try await readProfiles(binary: binary, namespace: namespace)
        #expect(profiles.version == ACPProfileBundle.currentVersion)
        #expect(profiles.profiles.count == 3)
        #expect(profiles.profiles.map(\.id) == profiles.profiles.map(\.id).sorted())
        #expect(profiles.profiles.map(\.id) == refreshedProfiles.profiles.map(\.id))
        #expect(profiles.profiles.map(\.args) == refreshedProfiles.profiles.map(\.args))

        let sharedProfiles = profiles.profiles.filter { $0.args.contains(sharedRuntimeID.uuidString.lowercased()) }
        #expect(sharedProfiles.count == 2)
        #expect(sharedProfiles.allSatisfy { $0.args.contains("--runtime") && $0.args.contains("--node") })
        #expect(!sharedProfiles.contains { $0.args.contains("--ascendant") })
        #expect(Set(sharedProfiles.compactMap { value(after: "--node", in: $0.args) }) == [
            firstNodeID.uuidString.lowercased(), secondNodeID.uuidString.lowercased(),
        ])

        let uniqueProfile = try #require(profiles.profiles.first {
            $0.args.contains(uniqueRuntimeID.uuidString.lowercased())
        })
        #expect(uniqueProfile.args.contains("--runtime"))
        #expect(!uniqueProfile.args.contains("--node"))
        #expect(!uniqueProfile.args.contains("--ascendant"))
    }

    @Test(
        "the shipped command line advertises its ACP and serve commands",
        .timeLimit(.minutes(1)),
        .enabled(if: ProcessInfo.processInfo.environment["GNOSTIC_ACP_BINARY"] != nil, "GNOSTIC_ACP_BINARY is not set")
    )
    func advertisesItsCommands() async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["GNOSTIC_ACP_BINARY"])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--help"]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        while process.isRunning {
            try await Task.sleep(for: .milliseconds(50))
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let standardError = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, Comment(rawValue: standardError))
        let help = String(decoding: data, as: UTF8.self)
        #expect(help.contains("acp"))
        #expect(help.contains("serve"))
        #expect(help.contains("config"))
    }
}

@MainActor
private func makeACPProfileProvider(
    name: String,
    namespace: String,
    runtimes: [(id: UUID, nodeID: UUID, name: String)]
) throws -> CommunicationManager {
    let manager = try CommunicationManager(
        identity: Identity(name: name),
        communicationOptions: CommunicationOptions(
            namespace: namespace,
            shouldEnableCrossNamespacing: false,
            mqttClientOptions: MQTTClientOptions(
                host: "127.0.0.1",
                port: 1883,
                shouldTryMDNSDiscovery: false,
                autoReconnect: false
            ),
            shouldAutoStart: false
        ),
        commonOptions: nil
    )
    for runtime in runtimes {
        manager.publishAdvertise(GnosticRuntimeInstanceObject(
            id: runtime.id,
            name: runtime.name,
            kind: "fixture",
            nodeID: runtime.nodeID,
            rawCapabilities: ["session": .object([:])]
        ))
    }
    return manager
}

@MainActor
private func startACPProfileProvider(_ manager: CommunicationManager) async throws {
    let stream = await manager.observeCommunicationStateStream()
    var iterator = stream.makeAsyncIterator()
    try manager.start()
    while let state = await iterator.next() {
        if state == .online { return }
    }
    throw CancellationError()
}

private func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

private func readProfiles(binary: String, namespace: String) async throws -> ACPProfileBundle {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = [
        "acp", "profiles", "--json", "--refresh",
        "--host", "127.0.0.1",
        "--port", "1883",
        "--namespace", namespace,
    ]
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    try process.run()
    while process.isRunning {
        try await Task.sleep(for: .milliseconds(50))
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let standardError = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus == 0, Comment(rawValue: standardError))
    return try JSONDecoder().decode(ACPProfileBundle.self, from: data)
}
