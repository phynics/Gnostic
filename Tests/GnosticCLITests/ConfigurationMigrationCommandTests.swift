// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@Suite("Configuration migration command", .serialized)
struct ConfigurationMigrationCommandTests {
    @Test("dry run previews the v0.5 manifest and leaves the source untouched")
    func dryRunPreviewsMigration() async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["GNOSTIC_CLI_BINARY"])
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/operator-schema-v2.json")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("config.json")
        let bytes = try Data(contentsOf: source)
        try bytes.write(to: path)

        let result = try await run(binary: binary, path: path, dryRun: true)
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let report = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(report["mode"] as? String == "dryRun")
        #expect(report["backup"] == nil)
        #expect((report["changedFields"] as? [String])?.contains("ascendants → runtimeInstances") == true)
        #expect((report["changedFields"] as? [String])?.contains("timelines[].operatingAscendantID → runtimeInstanceID") == true)
        #expect(!result.stdout.contains("fixture-secret"))
        #expect(try Data(contentsOf: path) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["config.json"])
    }

    @Test("apply creates an exact timestamped backup before writing the canonical shape")
    func applyMigratesWithBackup() async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["GNOSTIC_CLI_BINARY"])
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/operator-schema-v2.json")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("config.json")
        let original = try Data(contentsOf: source)
        try original.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let originalPermissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions]

        let result = try await run(binary: binary, path: path, dryRun: false)
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let report = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let backupPath = try #require(report["backup"] as? String)
        #expect(backupPath.contains("config.json.pre-v0.5-"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: backupPath)) == original)
        let backupPermissions = try FileManager.default.attributesOfItem(atPath: backupPath)[.posixPermissions]
        let migratedPermissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions]
        #expect(backupPermissions as? NSNumber == originalPermissions as? NSNumber)
        #expect(migratedPermissions as? NSNumber == originalPermissions as? NSNumber)

        let migrated = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        #expect(migrated["ascendants"] == nil)
        let runtimeInstances = try #require(migrated["runtimeInstances"] as? [[String: Any]])
        #expect(runtimeInstances.first?["id"] as? String == "A6420000-0000-4000-8000-000000000002")
        #expect((runtimeInstances.first?["metadata"] as? [String: String])?["label"] == "support")
        let node = try #require(migrated["node"] as? [String: Any])
        #expect(node["id"] as? String == "A6420000-0000-4000-8000-000000000001")
        let timelines = try #require(migrated["timelines"] as? [[String: Any]])
        #expect(timelines.first?["id"] as? String == "A6420000-0000-4000-8000-000000000003")
        #expect(timelines.first?["runtimeInstanceID"] as? String == "A6420000-0000-4000-8000-000000000002")
        #expect(Set(timelines.first?["flags"] as? [String] ?? []) == ["experiment", "support"])
        let workspaces = try #require(migrated["workspaces"] as? [[String: Any]])
        #expect(workspaces.first?["id"] as? String == "A6420000-0000-4000-8000-000000000004")
        let backend = try #require(runtimeInstances.first?["backend"] as? [String: Any])
        let settings = try #require(backend["settings"] as? [String: Any])
        #expect(settings["command"] as? String == "/usr/bin/node")
        let migratedText = String(decoding: try Data(contentsOf: path), as: UTF8.self)
        #expect(migratedText.contains("fixture-secret"))
    }

    @Test("removed in-process backends fail with remediation and keep the source untouched")
    func removedBackendsAreRejected() async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["GNOSTIC_CLI_BINARY"])
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/operator-schema-v2.json")
        for kind in ["positronic", "letta"] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let path = folder.appendingPathComponent("config.json")
            let sourceText = try String(contentsOf: fixture, encoding: .utf8)
                .replacingOccurrences(of: "acp-client", with: kind)
            let source = Data(sourceText.utf8)
            try source.write(to: path)

            let result = try await run(binary: binary, path: path, dryRun: false)
            #expect(result.status != 0)
            #expect(result.stderr.contains(kind))
            #expect(result.stderr.contains("ACP v2 Runtime"))
            #expect(try Data(contentsOf: path) == source)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["config.json"])
        }
    }

    @Test("schema-v1 migration remains unsupported and leaves the file untouched")
    func schemaV1IsNotRevived() async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["GNOSTIC_CLI_BINARY"])
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/operator-schema-v2.json")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("config.json")
        let source = Data(try String(contentsOf: fixture, encoding: .utf8)
            .replacingOccurrences(of: "\"schemaVersion\": 2", with: "\"schemaVersion\": 1")
            .utf8)
        try source.write(to: path)

        let result = try await run(binary: binary, path: path, dryRun: false)
        #expect(result.status != 0)
        #expect(result.stderr.contains("Schema-v1 migration is not supported"))
        #expect(try Data(contentsOf: path) == source)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["config.json"])
    }

    @Test("older schema-v2 aliases are outside the immediate pre-v0.5 migration scope")
    func olderSchemaV2AliasesAreRejected() async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["GNOSTIC_CLI_BINARY"])
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/operator-schema-v2.json")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("config.json")
        let source = Data(try String(contentsOf: fixture, encoding: .utf8)
            .replacingOccurrences(of: "defaultTimelineID", with: "timelineID")
            .utf8)
        try source.write(to: path)

        let result = try await run(binary: binary, path: path, dryRun: false)
        #expect(result.status != 0)
        #expect(result.stderr.contains("Older configuration formats are not supported"))
        #expect(try Data(contentsOf: path) == source)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["config.json"])
    }

    private func run(binary: String, path: URL, dryRun: Bool) async throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["config", "migrate"] + (dryRun ? ["--dry-run"] : []) + ["--format", "json", "--config", path.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        while process.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        return (
            process.terminationStatus,
            String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}
