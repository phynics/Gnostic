// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import PKContracts
import Testing

@Suite("Backend settings schema and registry enumeration")
struct BackendSettingsSchemaTests {
    @Test("a registry enumerates the kinds it can build")
    @MainActor
    func registryEnumeratesKinds() {
        var registry = AscendantAdapterRegistry()
        #expect(registry.registeredKinds == [AscendantAdapterRegistry.positronicKind])

        registry.registerBackend(kind: "fixture") { _, _, _, _ in
            fatalError("not constructed in this test")
        }
        #expect(registry.registeredKinds == [AscendantAdapterRegistry.positronicKind, "fixture"])
    }

    @Test("a Workspace registry enumerates the kinds it can build")
    func workspaceRegistryEnumeratesKinds() {
        var registry = WorkspaceAdapterRegistry()
        #expect(registry.registeredKinds == ["echo"])

        registry.registerProduct(kind: "ledger") { _ in
            fatalError("not constructed in this test")
        }
        #expect(registry.registeredKinds == ["echo", "ledger"])
    }

    @Test("the bundled Positronic backend advertises its setting and secret keys")
    @MainActor
    func positronicAdvertisesItsKeys() throws {
        let registry = AscendantAdapterRegistry()
        let schema = try #require(registry.settingsSchema(for: AscendantAdapterRegistry.positronicKind))

        #expect(schema.settingNames == ["provider", "endpoint", "model", "utilityModel", "fastModel", "extensions"])
        #expect(schema.secretNames == ["apiKey"])
        #expect(schema.key(named: "apiKey")?.isSecret == true)
        #expect(schema.key(named: "provider")?.isSecret == false)
        #expect(schema.key(named: "nonsense") == nil)
        // Every advertised key carries a summary a CLI can print in --help.
        #expect(schema.keys.allSatisfy { !$0.summary.isEmpty })
    }

    @Test("a backend registered without a schema advertises none rather than guessing")
    @MainActor
    func unspecifiedSchemaIsExplicit() {
        var registry = AscendantAdapterRegistry()
        registry.registerBackend(kind: "opaque") { _, _, _, _ in
            fatalError("not constructed in this test")
        }

        let schema = registry.settingsSchema(for: "opaque")
        #expect(schema?.isUnspecified == true)
        #expect(registry.settingsSchema(for: "never-registered") == nil)
    }

    @Test("the Positronic adapter validates against the schema it advertises")
    @MainActor
    func adapterValidatesAgainstItsAdvertisedSchema() {
        // The adapter must not carry a second, drifting list of key names.
        let advertised = Set(PositronicAscendantAdapter.settingsSchema.settingNames)
        #expect(advertised == ["provider", "endpoint", "model", "utilityModel", "fastModel", "extensions"])
        #expect(PositronicAscendantAdapter.settingsSchema.secretNames == ["apiKey"])
    }
}
