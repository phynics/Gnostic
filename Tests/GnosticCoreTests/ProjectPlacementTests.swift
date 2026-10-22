import Foundation
import GnosticCore
import Testing

@Suite("Project placement")
struct ProjectPlacementTests {
    @Test("local Projects resolve only existing absolute directories")
    func localProjectResolution() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: false)
        let resolver = ProjectDirectoryResolver(scratchRoot: root.appendingPathComponent("scratch"))

        let resolved = try resolver.resolve(.local(projectURL.path))
        #expect(resolved.kind == .local)
        #expect(resolved.cwd == projectURL.standardizedFileURL.path)
        #expect(!resolved.isManagedScratch)

        #expect(throws: ProjectValidationError.self) {
            try Project.local("relative/project").validate()
        }
        #expect(throws: ProjectPlacementError.self) {
            try resolver.resolve(.local(root.appendingPathComponent("missing").path))
        }
        #expect(throws: ProjectPlacementError.self) {
            try resolver.resolve(.local(projectURL.appendingPathComponent("file.txt").path))
        }
    }

    @Test("scratch Projects are unique, owner-only, and removable")
    func scratchProjectLifecycle() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let scratchRoot = root.appendingPathComponent("managed", isDirectory: true)
        let resolver = ProjectDirectoryResolver(scratchRoot: scratchRoot)

        let first = try resolver.resolve(.scratch)
        let second = try resolver.resolve(.scratch)
        #expect(first.cwd != second.cwd)
        #expect(first.isManagedScratch)
        #expect(first.cwd.hasPrefix(scratchRoot.path + "/"))
        #expect(URL(fileURLWithPath: first.cwd).lastPathComponent.hasPrefix(ProjectDirectoryResolver.scratchDirectoryPrefix))

        let attributes = try FileManager.default.attributesOfItem(atPath: first.cwd)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(resolver.isUsableDirectory(first.cwd))
        try resolver.discard(first)
        #expect(!FileManager.default.fileExists(atPath: first.cwd))
        #expect(FileManager.default.fileExists(atPath: second.cwd))
    }

    @Test("Timeline manifest round-trips Project placement and rejects invalid shape")
    func timelineManifestProjectRoundTrip() throws {
        let broker = NodeManifest.Broker(host: "localhost", port: 1883, namespace: "project-test")
        let project = Project.local("/workspace/repository")
        var manifest = NodeManifest.empty(broker: broker)
        manifest.timelines = [.init(id: UUID(), title: "Repository", project: project)]

        try manifest.validate()
        let encoded = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(NodeManifest.self, from: encoded)
        #expect(decoded == manifest)
        #expect(decoded.timelines.first?.project == project)

        manifest.timelines[0].project = .local("relative/repository")
        #expect(throws: NodeManifestError.invalidProject(manifest.timelines[0].id)) {
            try manifest.validate()
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-project-test-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
