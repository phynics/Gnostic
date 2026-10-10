// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing
@testable import GnosticCore

/// Characterizes the single absent-capability outcome: a backend that does
/// not declare an optional surface gets the same typed error no matter which
/// Core site asks for it, and an explicit optional lookup stays a no-op.
@MainActor
@Suite("Ascendant Backend capability declaration")
struct AscendantBackendCapabilityDeclarationTests {
    @Test("an undeclared surface throws the typed capability error even when the type conforms")
    func undeclaredSurfaceThrowsEvenWhenConforming() throws {
        let backend = CapabilityDeclarationFixtureBackend(declared: [])

        do {
            _ = try backend.requireCapability(.workspace, as: (any AscendantBackendWorkspaceCapability).self)
            Issue.record("requireCapability returned for an undeclared surface")
        } catch let error as AscendantBackendError {
            #expect(error == .capabilityUnavailable(.workspace))
            #expect(error.reasonCode == "capabilityUnavailable")
            #expect(error.statusCode == 501)
        }
    }

    @Test("a declared surface the type does not implement throws the same typed error")
    func declaredButNonConformingThrowsSameError() throws {
        let backend = CapabilityDeclarationFixtureBackend(declared: [.turnCancellation])

        do {
            _ = try backend.requireCapability(.turnCancellation, as: (any AscendantBackendTurnCancellation).self)
            Issue.record("requireCapability returned for a surface the type does not implement")
        } catch let error as AscendantBackendError {
            #expect(error == .capabilityUnavailable(.turnCancellation))
        }
    }

    @Test("a declared, implemented surface is returned")
    func declaredAndImplementedIsReturned() async throws {
        let backend = CapabilityDeclarationFixtureBackend(declared: [.workspace])

        let workspace = try backend.requireCapability(.workspace, as: (any AscendantBackendWorkspaceCapability).self)
        let enabled = await workspace.enabledToolIDs(for: UUID())
        #expect(enabled.isEmpty)
    }

    @Test("an explicit optional lookup returns nil for an undeclared surface")
    func explicitOptionalLookupIsNilWhenUndeclared() {
        let backend = CapabilityDeclarationFixtureBackend(declared: [])

        #expect(backend.optionalCapability(.workspace, as: (any AscendantBackendWorkspaceCapability).self) == nil)
    }

    @Test("the declaration is a set, so several surfaces can be declared together")
    func declarationIsASet() {
        let declared: AscendantBackendCapabilities = [.workspace, .turnCancellation]

        #expect(declared.contains(.workspace))
        #expect(declared.contains(.turnCancellation))
        #expect(!declared.contains(.workspaceFiles))
        #expect(!declared.contains(.timelineStore))
    }
}

/// A backend whose declaration is supplied by the test. The class implements
/// Workspace tool-call operations so one declared surface is observable.
@MainActor
private final class CapabilityDeclarationFixtureBackend: AscendantBackend, AscendantBackendWorkspaceCapability {
    let identity: AscendantBackendIdentity
    let capabilities: AscendantBackendCapabilities

    init(declared: AscendantBackendCapabilities) {
        capabilities = declared
        let now = Date()
        identity = .init(
            id: UUID(),
            name: "Declaration fixture",
            description: "",
            privateTimelineID: UUID(),
            primaryWorkspaceID: nil,
            lastActiveAt: now,
            createdAt: now,
            updatedAt: now
        )
    }

    func validateConfiguration() throws {}
    func operatedTimelines() async throws -> [AscendantBackendTimeline] { [] }
    func createTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        throw AscendantBackendError.invalidConfiguration("unsupported in fixture")
    }
    func removeTimeline(id _: UUID) async {}
    func renameTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        throw AscendantBackendError.timelineNotFound(id)
    }
    func runTurn(_ request: AscendantBackendTurnRequest, updates _: any AscendantBackendUpdateSink) async throws -> String {
        request.message
    }
    func cancel() async {}
    func shutdown() async {}
    func attachWorkspace(_: BackendWorkspaceReference, to _: UUID) async throws {}
    func detachWorkspace(_: UUID, from _: UUID) async throws {}
    func enabledToolIDs(for _: UUID) async -> [String] { [] }
}
