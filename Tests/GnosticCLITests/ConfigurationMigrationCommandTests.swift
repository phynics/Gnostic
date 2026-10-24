// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing
@testable import GnosticCLI
#if os(Linux)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

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
        #expect(try onlySourceAndLockRemain(in: folder))
    }

    @Test("apply creates an exact timestamped backup before writing the canonical shape")
    func applyMigratesWithBackup() async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["GNOSTIC_CLI_BINARY"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("config.json")
        let original = Data(try fixtureTextIncludingScratchRoot().utf8)
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
        #expect(settings["scratchRoot"] as? String == "/tmp/gnostic-scratch")
        let migratedText = String(decoding: try Data(contentsOf: path), as: UTF8.self)
        #expect(migratedText.contains("fixture-secret"))
    }

    @Test("invalid environment object names are rejected")
    func invalidEnvironmentObjectNameIsRejected() async throws {
        let fixture = try fixtureText()
        let source = fixture.replacingOccurrences(of: #"{\"MODE\":\"safe\"}"#, with: #"{\"9MODE\":\"safe\"}"#)
        try await expectRejected(Data(source.utf8), label: "invalid env object name")
    }

    @Test("blank ACP working directories are rejected")
    func blankWorkingDirectoryIsRejected() async throws {
        let fixture = try fixtureText()
        let source = fixture.replacingOccurrences(
            of: "\"command\": \"/usr/bin/node\"",
            with: "\"command\": \"/usr/bin/node\",\n          \"cwd\": \"  \""
        )
        try await expectRejected(Data(source.utf8), label: "blank cwd")
    }

    @Test("blank ACP display names are rejected")
    func blankDisplayNameIsRejected() async throws {
        let fixture = try fixtureText()
        let source = fixture.replacingOccurrences(
            of: "\"command\": \"/usr/bin/node\"",
            with: "\"command\": \"/usr/bin/node\",\n          \"displayName\": \"  \""
        )
        try await expectRejected(Data(source.utf8), label: "blank display name")
    }

    @Test("relative ACP scratch roots are rejected")
    func relativeScratchRootIsRejected() async throws {
        let fixture = try fixtureTextIncludingScratchRoot()
        let source = fixture.replacingOccurrences(
            of: "\"scratchRoot\": \"/tmp/gnostic-scratch\"",
            with: "\"scratchRoot\": \"relative/scratch\""
        )
        try await expectRejected(Data(source.utf8), label: "relative scratch root")
    }

    @Test("environment object and plain ACP environment definitions cannot repeat a name")
    func duplicateEnvironmentObjectAndPlainSettingAreRejected() async throws {
        let fixture = try fixtureText()
        let duplicatePlain = fixture.replacingOccurrences(
            of: "\"env\": \"{\\\"MODE\\\":\\\"safe\\\"}\"",
            with: "\"env\": \"{\\\"MODE\\\":\\\"safe\\\"}\",\n          \"env.MODE\": \"override\""
        )
        try await expectRejected(Data(duplicatePlain.utf8), label: "env and env.MODE duplicate")
    }

    @Test("environment object and secret ACP environment definitions cannot repeat a name")
    func duplicateEnvironmentObjectAndSecretSettingAreRejected() async throws {
        let fixture = try fixtureText()
        let duplicateSecret = fixture.replacingOccurrences(
            of: "\"env-secret.API_TOKEN\": \"fixture-secret\"",
            with: "\"env-secret.API_TOKEN\": \"fixture-secret\",\n        \"env-secret.MODE\": \"secret-override\""
        )
        try await expectRejected(Data(duplicateSecret.utf8), label: "env and env-secret.MODE duplicate")
    }

    @Test("plain and secret ACP environment definitions cannot repeat a name")
    func duplicatePlainAndSecretSettingsAreRejected() async throws {
        let fixture = try fixtureText()
        let duplicateDynamic = fixture.replacingOccurrences(
            of: "\"env\": \"{\\\"MODE\\\":\\\"safe\\\"}\"",
            with: "\"env\": \"{}\",\n          \"env.MODE\": \"plain\""
        ).replacingOccurrences(
            of: "\"env-secret.API_TOKEN\": \"fixture-secret\"",
            with: "\"env-secret.API_TOKEN\": \"fixture-secret\",\n        \"env-secret.MODE\": \"secret\""
        )
        try await expectRejected(Data(duplicateDynamic.utf8), label: "env.MODE and env-secret.MODE duplicate")
    }

    @Test("a source change after the migration read is detected before backup or replacement")
    func sourceChangeDuringMigrationIsDetected() throws {
        let source = Data(try fixtureText().utf8)
        let concurrentUpdate = Data(try fixtureText().replacingOccurrences(of: "migration-test", with: "concurrent-update").utf8)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("config.json")
        try source.write(to: path)
        var transactionLockHeld = false

        #expect(throws: ConfigurationMigrationError.self) {
            try ConfigurationMigration.migrateForTesting(at: path, dryRun: false) {
                transactionLockHeld = isManifestLockHeld(for: path)
                try? concurrentUpdate.write(to: path)
            }
        }
        #expect(transactionLockHeld)
        #expect(try Data(contentsOf: path) == concurrentUpdate)
        #expect(try onlySourceAndLockRemain(in: folder))
    }

    @Test("a source change after backup is detected and the stale backup is removed")
    func sourceChangeAfterBackupIsDetected() throws {
        let source = Data(try fixtureText().utf8)
        let concurrentUpdate = Data(try fixtureText().replacingOccurrences(of: "migration-test", with: "concurrent-update").utf8)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("config.json")
        try source.write(to: path)
        var transactionLockHeld = false

        #expect(throws: ConfigurationMigrationError.self) {
            try ConfigurationMigration.migrateForTesting(at: path, dryRun: false, afterReadingSource: {}) {
                transactionLockHeld = isManifestLockHeld(for: path)
                try? concurrentUpdate.write(to: path)
            }
        }
        #expect(transactionLockHeld)
        #expect(try Data(contentsOf: path) == concurrentUpdate)
        #expect(try onlySourceAndLockRemain(in: folder))
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
            #expect(try onlySourceAndLockRemain(in: folder))
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
        #expect(try onlySourceAndLockRemain(in: folder))
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
        #expect(try onlySourceAndLockRemain(in: folder))
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

    private func fixtureText() throws -> String {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/operator-schema-v2.json")
        return try String(contentsOf: fixture, encoding: .utf8)
    }

    private func fixtureTextIncludingScratchRoot() throws -> String {
        try fixtureText().replacingOccurrences(
            of: "\"command\": \"/usr/bin/node\"",
            with: "\"command\": \"/usr/bin/node\",\n          \"scratchRoot\": \"/tmp/gnostic-scratch\""
        )
    }

    private func isManifestLockHeld(for path: URL) -> Bool {
        let lockPath = path.deletingLastPathComponent()
            .appendingPathComponent(".\(path.lastPathComponent).lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return false }
        defer { _ = close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(descriptor, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK || errno == EAGAIN
    }

    private func onlySourceAndLockRemain(in folder: URL) throws -> Bool {
        let entries = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0 != ".config.json.lock" }
        return entries == ["config.json"]
    }

    private func expectRejected(_ source: Data, label: String) async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["GNOSTIC_CLI_BINARY"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("config.json")
        try source.write(to: path)

        let result = try await run(binary: binary, path: path, dryRun: false)
        #expect(result.status != 0, "Migration unexpectedly accepted: \(label)")
        #expect(try Data(contentsOf: path) == source)
        #expect(try onlySourceAndLockRemain(in: folder))
    }
}
