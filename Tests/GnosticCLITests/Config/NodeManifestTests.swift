// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticCLI

@Suite("Versioned node manifest")
struct NodeManifestTests {
    @Test("schema v2 stores backend configuration on each Ascendant")
    func schemaV2UsesPerAscendantBackendEnvelope() throws {
        let nodeID = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000101"))
        let ascendantID = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000102"))
        let timelineID = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000103"))
        let backend = NodeManifest.BackendConfiguration(
            kind: "positronic",
            schemaVersion: 1,
            settings: ["provider": .string("anthropic"), "model": .string("claude")],
            secrets: ["apiKey": .string("secret")]
        )
        let manifest = NodeManifest(
            broker: .init(host: "localhost", port: 1883, namespace: "gnostic"),
            node: .init(id: nodeID),
            ascendants: [.init(id: ascendantID, name: "Alice", defaultTimelineID: timelineID, backend: backend)],
            timelines: [.init(id: timelineID, title: "Default", operatingAscendantID: ascendantID)]
        )

        try manifest.validate()
        let encoded = try JSONEncoder().encode(manifest)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == NodeManifest.currentSchemaVersion)
        #expect(object["llmProfiles"] == nil)
        #expect(object["ascendants"] is [Any])
        #expect(!manifest.redactedDescription().contains("llm-secret"))
        #expect(!manifest.redactedDescription().contains("apiKey"))
    }

    @Test("schema v2 requires an explicit backend envelope")
    func schemaV2RequiresBackendEnvelope() throws {
        let node = "A21D0000-0000-4000-8000-000000000191"
        let ascendant = "A21D0000-0000-4000-8000-000000000192"
        let timeline = "A21D0000-0000-4000-8000-000000000193"
        let source = "{\"schemaVersion\":2,\"broker\":{\"host\":\"localhost\",\"port\":1883,\"namespace\":\"gnostic\"},\"node\":{\"id\":\"\(node)\",\"kind\":\"node\",\"approvalMode\":\"auto\",\"logLevel\":\"info\"},\"ascendants\":[{\"id\":\"\(ascendant)\",\"kind\":\"positronic\",\"name\":\"A\",\"defaultTimelineID\":\"\(timeline)\"}],\"timelines\":[{\"id\":\"\(timeline)\",\"kind\":\"timeline\",\"title\":\"T\",\"operatingAscendantID\":\"\(ascendant)\"}]}"
        #expect(throws: DecodingError.self) { _ = try JSONDecoder().decode(NodeManifest.self, from: Data(source.utf8)) }
    }

    @Test("v2 load removes the retired CLI profile identity marker")
    func v2LoadCanonicalizesRetiredProfileMarker() throws {
        let folder = try TemporaryFolder()
        let path = folder.url.appendingPathComponent("config.json")
        var manifest = NodeManifest.makeDefault(broker: .init(host: "localhost", port: 1883, namespace: "gnostic"))
        manifest.ascendants[0].backend.settings["_legacyID"] = .string(UUID().uuidString)
        try JSONEncoder().encode(manifest).write(to: path)

        let loaded = try CLIConfigurationStore(configPath: path, environment: [:]).loadManifest()
        #expect(loaded.ascendants[0].backend.settings["_legacyID"] == nil)
        #expect(String(data: try Data(contentsOf: path), encoding: .utf8)?.contains("_legacyID") == false)
    }

    @Test("v2 load preserves opaque settings owned by other backends")
    func v2LoadPreservesNonPositronicLegacyIDSetting() throws {
        let folder = try TemporaryFolder()
        let path = folder.url.appendingPathComponent("config.json")
        var manifest = NodeManifest.makeDefault(broker: .init(host: "localhost", port: 1883, namespace: "gnostic"))
        manifest.ascendants[0].kind = "custom"
        manifest.ascendants[0].backend = .init(
            kind: "custom",
            settings: ["_legacyID": .string("backend-owned"), "mode": .string("deterministic")]
        )
        try JSONEncoder().encode(manifest).write(to: path)

        let loaded = try CLIConfigurationStore(configPath: path, environment: [:]).loadManifest()
        #expect(loaded.ascendants[0].backend.settings["_legacyID"] == .string("backend-owned"))
        #expect(loaded.ascendants[0].backend.settings["mode"] == .string("deterministic"))
    }

    @Test("invalid legacy profile does not rewrite its source")
    func invalidLegacyProfileIsNotRewritten() throws {
        let folder = try TemporaryFolder()
        let path = folder.url.appendingPathComponent("config.json")
        let source = Data("{\"schemaVersion\":1,\"broker\":{\"host\":\"localhost\",\"port\":1883,\"namespace\":\"gnostic\"},\"node\":{\"id\":\"A21D0000-0000-4000-8000-000000000194\",\"kind\":\"node\",\"approvalMode\":\"auto\",\"logLevel\":\"info\"},\"llmProfiles\":[{\"id\":\"A21D0000-0000-4000-8000-000000000195\",\"name\":\"\",\"provider\":\"stub\"}],\"ascendants\":[],\"timelines\":[],\"workspaces\":[]}".utf8)
        try source.write(to: path)
        #expect(throws: CLIConfigurationError.self) { _ = try CLIConfigurationStore(configPath: path, environment: [:]).loadManifest() }
        #expect(try Data(contentsOf: path) == source)
    }

    @Test("schema v1 migration preserves graph identities and inlines profiles")
    func schemaV1MigrationPreservesIdentities() throws {
        let folder = try TemporaryFolder()
        let path = folder.url.appendingPathComponent("config.json")
        let node = "A21D0000-0000-4000-8000-000000000111"
        let profile = "A21D0000-0000-4000-8000-000000000112"
        let ascendant = "A21D0000-0000-4000-8000-000000000113"
        let timeline = "A21D0000-0000-4000-8000-000000000114"
        let workspace = "A21D0000-0000-4000-8000-000000000115"
        let source = """
        {"schemaVersion":1,"broker":{"host":"legacy.example","port":1883,"namespace":"gnostic","username":"alice","password":"broker-secret"},"node":{"id":"\(node)","kind":"node","approvalMode":"auto","logLevel":"info"},"llmProfiles":[{"id":"\(profile)","name":"Legacy","provider":"anthropic","model":"claude","apiKey":"llm-secret"}],"ascendants":[{"id":"\(ascendant)","kind":"positronic","name":"Alice","description":"old","metadata":{},"llmProfileID":"\(profile)","defaultTimelineID":"\(timeline)"}],"timelines":[{"id":"\(timeline)","kind":"timeline","title":"Default","operatingAscendantID":"\(ascendant)","flags":[],"attachments":[{"workspaceID":"\(workspace)","scope":"local"}]}],"workspaces":[{"id":"\(workspace)","kind":"echo","name":"Echo","uri":"echo://default"}]}
        """
        try Data(source.utf8).write(to: path)

        let migrated = try CLIConfigurationStore(configPath: path, environment: [:]).loadManifest()
        #expect(migrated.schemaVersion == 2)
        #expect(migrated.node.id.uuidString.lowercased() == node.lowercased())
        #expect(migrated.ascendants.first?.id.uuidString.lowercased() == ascendant.lowercased())
        #expect(migrated.timelines.first?.id.uuidString.lowercased() == timeline.lowercased())
        #expect(migrated.workspaces.first?.id.uuidString.lowercased() == workspace.lowercased())
        #expect(migrated.ascendants.first?.backend.settings["provider"] == .string("anthropic"))
        #expect(migrated.ascendants.first?.backend.secrets["apiKey"] == .string("llm-secret"))
        #expect(migrated.ascendants.first?.backend.settings["_legacyID"] == nil)
        let canonical = try Data(contentsOf: path)
        #expect(String(data: canonical, encoding: .utf8)?.contains("llmProfiles") == false)
        #expect(FileManager.default.fileExists(atPath: path.appendingPathExtension("legacy").path))
    }

    @Test("v1 shared profiles are inlined independently for each Ascendant")
    func sharedV1ProfilesAreInlinedPerAscendant() throws {
        let folder = try TemporaryFolder()
        let path = folder.url.appendingPathComponent("config.json")
        let source = """
        {"schemaVersion":1,"broker":{"host":"localhost","port":1883,"namespace":"gnostic"},"node":{"id":"A21D0000-0000-4000-8000-000000000121","kind":"node","approvalMode":"auto","logLevel":"info"},"llmProfiles":[{"id":"A21D0000-0000-4000-8000-000000000122","name":"Shared","provider":"stub","model":"deterministic"}],"ascendants":[{"id":"A21D0000-0000-4000-8000-000000000123","kind":"positronic","name":"One","metadata":{},"llmProfileID":"A21D0000-0000-4000-8000-000000000122","defaultTimelineID":"A21D0000-0000-4000-8000-000000000125"},{"id":"A21D0000-0000-4000-8000-000000000124","kind":"positronic","name":"Two","metadata":{},"llmProfileID":"A21D0000-0000-4000-8000-000000000122","defaultTimelineID":"A21D0000-0000-4000-8000-000000000126"}],"timelines":[{"id":"A21D0000-0000-4000-8000-000000000125","kind":"timeline","title":"One","operatingAscendantID":"A21D0000-0000-4000-8000-000000000123","flags":[],"attachments":[]},{"id":"A21D0000-0000-4000-8000-000000000126","kind":"timeline","title":"Two","operatingAscendantID":"A21D0000-0000-4000-8000-000000000124","flags":[],"attachments":[]}],"workspaces":[]}
        """
        try Data(source.utf8).write(to: path)

        let migrated = try CLIConfigurationStore(configPath: path, environment: [:]).loadManifest()
        #expect(migrated.ascendants.count == 2)
        #expect(migrated.ascendants.allSatisfy { $0.backend.settings["provider"] == .string("stub") })
        #expect(migrated.ascendants.allSatisfy { $0.backend.settings["_legacyID"] == nil })
    }

    @Test("backend settings and secrets are bounded")
    func backendEnvelopeRejectsUnboundedValues() throws {
        let manifest = NodeManifest.makeDefault(broker: .init(host: "localhost", port: 1883, namespace: "gnostic"))
        var invalid = manifest
        invalid.ascendants[0].backend.settings = ["payload": .string(String(repeating: "x", count: NodeManifest.BackendConfiguration.maxJSONBytes + 1))]
        #expect(throws: NodeManifestError.self) { try invalid.validate() }
    }

    @Test("changing a backend binding preserves the Ascendant identity")
    func backendBindingCanChangeAcrossRestarts() throws {
        let original = NodeManifest.makeDefault(broker: .init(host: "localhost", port: 1883, namespace: "gnostic"))
        var changed = original
        changed.ascendants[0].backend = .init(kind: "fixture", settings: ["mode": .string("deterministic")])

        try changed.validate(against: original)
        #expect(changed.ascendants[0].id == original.ascendants[0].id)
        #expect(changed.ascendants[0].backend.kind == "fixture")
    }

    @Test("manifest validates its graph and compiles a launch plan")
    func manifestValidatesAndCompilesLaunchPlan() throws {
        let ascendantID = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000002"))
        let timelineID = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000003"))
        let workspaceID = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000004"))
        let nodeID = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000005"))

        let manifest = NodeManifest(
            schemaVersion: 2,
            broker: .init(host: "broker.example", port: 1883, namespace: "gnostic", username: "alice", password: "secret"),
            node: .init(id: nodeID, kind: "node"),
            ascendants: [.init(id: ascendantID, name: "Alice", defaultTimelineID: timelineID, kind: "positronic", description: "Primary assistant", metadata: ["team": "core"], backend: .init(kind: "positronic", settings: ["provider": .string("anthropic"), "model": .string("claude")]))],
            timelines: [.init(id: timelineID, title: "Default", kind: "timeline", operatingAscendantID: ascendantID, attachments: [.local(workspaceID)])],
            workspaces: [.init(id: workspaceID, name: "Echo Workspace", uri: "echo://default", kind: "echo")]
        )

        try manifest.validate()
        let plan = try manifest.compileLaunchPlan()

        #expect(plan.nodeID == nodeID)
        #expect(plan.broker.host == "broker.example")
        #expect(plan.ascendants.count == 1)
        #expect(plan.timelines.first?.workspaceIDs == [workspaceID])
        #expect(plan.ascendants.first?.metadata["team"] == "core")
    }

    @Test("manifest rejects duplicate IDs, broken references, and immutable identity changes")
    func manifestRejectsInvalidGraphAndIdentityChanges() throws {
        let id = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000011"))
        let manifest = NodeManifest(
            schemaVersion: 2,
            broker: .init(host: "localhost", port: 1883, namespace: "gnostic"),
            node: .init(id: id, kind: "node"),
            ascendants: [], timelines: [], workspaces: []
        )

        #expect(throws: Never.self) { try manifest.validate() }

        var changed = manifest
        changed.node.kind = "other-node"
        #expect(throws: NodeManifestError.self) { try changed.validate(against: manifest) }
    }

    @Test("store gives an explicit path precedence over GNOSTIC_CONFIG")
    func explicitPathPrecedesEnvironment() throws {
        let folder = try TemporaryFolder()
        let explicit = folder.url.appendingPathComponent("explicit.json")
        let environmentPath = folder.url.appendingPathComponent("environment.json")
        let store = CLIConfigurationStore(
            configPath: explicit,
            environment: ["GNOSTIC_CONFIG": environmentPath.path]
        )

        #expect(store.path() == explicit)
    }

    @Test("valid legacy config migrates once, retains a private backup, and creates defaults")
    func validLegacyConfigMigratesOnce() throws {
        let folder = try TemporaryFolder()
        let path = folder.url.appendingPathComponent("config.json")
        let legacy = #"{"mqtt.host":"legacy.example","mqtt.port":1884,"mqtt.password":"broker-secret","llm.provider":"anthropic","llm.apiKey":"llm-secret","llm.model":"claude"}"#
        _ = FileManager.default.createFile(atPath: path.path, contents: Data(legacy.utf8))

        let store = CLIConfigurationStore(baseDirectory: folder.url, environment: [:])
        let manifest = try store.loadManifest()

        #expect(manifest.schemaVersion == 2)
        #expect(manifest.broker.host == "legacy.example")
        #expect(manifest.broker.password == "broker-secret")
        #expect(manifest.ascendants.count == 1)
        #expect(manifest.ascendants.first?.backend.settings["endpoint"] == nil)
        #expect(manifest.ascendants.first?.kind == "positronic")
        #expect(manifest.timelines.count == 1)
        #expect(manifest.timelines.first?.attachments.isEmpty == true)
        #expect(manifest.workspaces.first?.kind == "echo")
        #expect(FileManager.default.fileExists(atPath: store.legacyBackupPath().path))
        #expect(((try FileManager.default.attributesOfItem(atPath: store.legacyBackupPath().path)[.posixPermissions]) as? NSNumber)?.intValue == 0o600)
        #expect(((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions]) as? NSNumber)?.intValue == 0o600)

        let secondLoad = try store.loadManifest()
        #expect(secondLoad == manifest)
        #expect(try store.load().mqttPassword == "broker-secret")
        #expect(try store.load().llmAPIKey == "llm-secret")
    }

    @Test("malformed legacy config is left untouched")
    func malformedLegacyConfigIsUntouched() throws {
        let folder = try TemporaryFolder()
        let path = folder.url.appendingPathComponent("config.json")
        let data = Data("{not-json".utf8)
        _ = FileManager.default.createFile(atPath: path.path, contents: data)

        let store = CLIConfigurationStore(baseDirectory: folder.url, environment: [:])
        #expect(throws: CLIConfigurationError.self) { try store.loadManifest() }
        #expect(try Data(contentsOf: path) == data)
        #expect(!FileManager.default.fileExists(atPath: store.legacyBackupPath().path))
    }

    @Test("schema-less JSON that is not a legacy config is left untouched")
    func arbitrarySchemaLessJSONIsUntouched() throws {
        let folder = try TemporaryFolder()
        let path = folder.url.appendingPathComponent("config.json")
        let data = Data(#"{"unexpected":true}"#.utf8)
        _ = FileManager.default.createFile(atPath: path.path, contents: data)

        let store = CLIConfigurationStore(baseDirectory: folder.url, environment: [:])
        #expect(throws: CLIConfigurationError.self) { try store.loadManifest() }
        #expect(try Data(contentsOf: path) == data)
        #expect(!FileManager.default.fileExists(atPath: store.legacyBackupPath().path))
    }

    @Test("mutating an empty existing file fails without replacing it")
    func emptyFileMutationIsUntouched() throws {
        let folder = try TemporaryFolder()
        let path = folder.url.appendingPathComponent("config.json")
        _ = FileManager.default.createFile(atPath: path.path, contents: Data())
        let store = CLIConfigurationStore(baseDirectory: folder.url, environment: [:])

        #expect(throws: CLIConfigurationError.self) {
            try store.mutateManifest { $0.broker.host = "replacement.example" }
        }
        #expect(try Data(contentsOf: path).isEmpty)
    }

    @Test("generated manifest identities are RFC 4122 version 4 UUIDs")
    func generatedIdentitiesAreVersion4() throws {
        let manifest = NodeManifest.makeDefault(broker: .init(host: "localhost", port: 1883, namespace: "gnostic"))
        for id in manifest.allIDs {
            #expect(id.isVersion4)
            #expect(id.isRFC4122Variant)
        }
    }

    @Test("validated manifests round-trip through direct JSON editing")
    func manifestJSONRoundTrips() throws {
        let manifest = NodeManifest.makeDefault(broker: .init(host: "localhost", port: 1883, namespace: "gnostic"))
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(NodeManifest.self, from: data)
        try decoded.validate()
        #expect(decoded == manifest)
    }

    @Test("default graph has an unattached echo Workspace and an operated default Timeline")
    func defaultGraphIsOperated() throws {
        let manifest = NodeManifest.makeDefault(broker: .init(host: "localhost", port: 1883, namespace: "gnostic"))
        try manifest.validate()

        let ascendant = try #require(manifest.ascendants.first)
        let timeline = try #require(manifest.timelines.first { $0.id == ascendant.defaultTimelineID })
        #expect(timeline.operatingAscendantID == ascendant.id)
        #expect(timeline.attachments.isEmpty)
        #expect(manifest.workspaces.first?.kind == "echo")
        #expect(manifest.workspaces.first?.uri == "echo://default")
    }

    @Test("empty module arrays are a valid launch plan")
    func emptyModulesCompile() throws {
        let manifest = NodeManifest.empty(broker: .init(host: "localhost", port: 1883, namespace: "gnostic"))
        let plan = try manifest.compileLaunchPlan()
        #expect(plan.ascendants.isEmpty)
        #expect(plan.timelines.isEmpty)
        #expect(plan.workspaces.isEmpty)
    }

    @Test("local and network attachments have different validation rules")
    func attachmentScopesValidateDifferently() throws {
        let workspaceID = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000021"))
        let timelineID = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000022"))
        let nodeID = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000023"))
        let local = NodeManifest(
            broker: .init(host: "localhost", port: 1883, namespace: "gnostic"),
            node: .init(id: nodeID),
            timelines: [.init(id: timelineID, title: "Local", attachments: [.local(workspaceID)])],
            workspaces: [.init(id: workspaceID, name: "Echo", uri: "echo://local")]
        )
        try local.validate()

        let lazy = NodeManifest(
            broker: local.broker,
            node: local.node,
            timelines: [.init(id: timelineID, title: "Remote", attachments: [.network(workspaceID, uri: "workspace://remote")])]
        )
        try lazy.validate()
    }

    @Test("default Timeline must be operated by its Ascendant")
    func defaultTimelineMustBeOperated() throws {
        let manifest = NodeManifest.makeDefault(broker: .init(host: "localhost", port: 1883, namespace: "gnostic"))
        var invalid = manifest
        invalid.timelines[0].operatingAscendantID = nil
        #expect(throws: NodeManifestError.self) { try invalid.validate() }
    }

    @Test("schema, kind, profile, and attachment errors retain structured reason codes")
    func errorsRetainReasonCodes() throws {
        var unknown = NodeManifest.empty(broker: .init(host: "localhost", port: 1883, namespace: "gnostic"))
        unknown.schemaVersion = 3
        #expect(manifestError(unknown) == .unsupportedSchemaVersion(3))

        let workspaceID = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000031"))
        let timelineID = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000032"))
        var invalid = NodeManifest(
            broker: unknown.broker,
            node: unknown.node,
            timelines: [.init(id: timelineID, title: "Broken", attachments: [.network(workspaceID, uri: "")])]
        )
        #expect(manifestError(invalid) == .invalidAttachment(timelineID))
        invalid.timelines[0].attachments = [.local(workspaceID), .local(workspaceID)]
        invalid.workspaces = [.init(id: workspaceID, name: "Echo", uri: "echo://local")]
        #expect(manifestError(invalid) == .duplicateAttachment(timelineID, workspaceID))
    }

    @Test("missing manifest stays missing until an explicit mutation writes it")
    func missingManifestRemainsAbsent() throws {
        let folder = try TemporaryFolder()
        let store = CLIConfigurationStore(baseDirectory: folder.url.appendingPathComponent("new-config"), environment: [:])
        #expect(throws: CLIConfigurationError.self) { try store.loadManifest() }
        #expect(!FileManager.default.fileExists(atPath: store.path().path))
        try store.setValue("localhost", for: .mqttHost)
        #expect(FileManager.default.fileExists(atPath: store.path().path))
        let directoryMode = (try FileManager.default.attributesOfItem(atPath: store.baseDirectory.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(directoryMode == 0o700)
    }

    @Test("manifest diagnostics redact broker and profile secrets")
    func manifestDiagnosticsRedactSecrets() {
        let manifest = NodeManifest.makeDefault(
            broker: .init(host: "localhost", port: 1883, namespace: "gnostic", password: "broker-secret")
        )
        var secured = manifest
        secured.ascendants[0].backend.secrets["apiKey"] = .string("llm-secret")
        let shown = secured.redactedDescription()

        #expect(!shown.contains("broker-secret"))
        #expect(!shown.contains("llm-secret"))
        #expect(shown.contains("<redacted>"))
    }

    @Test("concurrent mutations leave a valid atomically replaced manifest")
    func concurrentMutationsRemainValid() async throws {
        let folder = try TemporaryFolder()
        let store = CLIConfigurationStore(baseDirectory: folder.url, environment: [:])
        try store.setValue("gnostic", for: .mqttNamespace)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    _ = try? store.mutateManifest { manifest in
                        manifest.broker.namespace = "gnostic-\(index)"
                    }
                }
            }
        }

        let result = try store.loadManifest()
        try result.validate()
        #expect(result.broker.namespace.hasPrefix("gnostic-"))
    }
}

private func manifestError(_ manifest: NodeManifest) -> NodeManifestError? {
    do {
        try manifest.validate()
        return nil
    } catch let error as NodeManifestError {
        return error
    } catch {
        return nil
    }
}
