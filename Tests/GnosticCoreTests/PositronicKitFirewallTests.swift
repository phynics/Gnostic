// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

/// The PositronicKit firewall is an architecture test, not a convention.
///
/// PositronicKit runs only in the standalone ACP Runtime process. The host,
/// core, protocol, client, kit, CLI, and frontend targets must not declare it,
/// import it, or reach it through another target's dependency closure.
@Suite("PositronicKit firewall")
struct PositronicKitFirewallTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The targets that may still declare a PositronicKit product.
    ///
    /// The list is explicit on purpose. A prefix rule would silently allow a
    /// new target that only looks transitional.
    ///
    /// - `GnosticPositronic*` is the backend family that #611 removes with the
    ///   transitional host composition.
    /// - `GnosticLegacy*` is the isolated transitional composition that #611
    ///   deletes.
    /// - `GnosticReferenceRuntime` is the standalone reference Runtime
    ///   executable that owns the only permitted PositronicKit link.
    private static let transitionalTargets: Set<String> = [
        "GnosticPositronicBackend",
        "GnosticPositronicAtlas",
        "GnosticPositronicContext",
        "GnosticPositronicBackendTests",
        "GnosticPositronicAtlasTests",
        "GnosticPositronicContextTests",
        "GnosticLegacyPositronicHost",
        "GnosticLegacyCLI",
        "GnosticLegacyCLITests",
        "GnosticReferenceRuntime",
    ]

    private static let hostTargets = [
        "GnosticProtocol",
        "GnosticCore",
        "GnosticClient",
        "GnosticKit",
        "GnosticHost",
        "GnosticCLI",
        "GnosticACPFrontend",
    ]

    @Test("no target outside the Runtime and transitional targets declares PositronicKit")
    func packageDeclarationsAreClean() throws {
        let package = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let targets = try parseTargets(package)
        for target in targets {
            guard !isAllowed(target.name) else { continue }
            for dependency in target.dependencies where isPositronicDependency(dependency) {
                Issue.record("Target \(target.name) declares PositronicKit dependency \(dependency).")
            }
        }
    }

    @Test("every non-transitional target closure contains no PositronicKit product")
    func hostClosuresAreClean() throws {
        let package = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let targets = try parseTargets(package)
        let byName = Dictionary(uniqueKeysWithValues: targets.map { ($0.name, $0) })
        for name in Self.hostTargets {
            _ = try #require(byName[name], "Package.swift has no target named \(name).")
        }
        for target in targets where !isAllowed(target.name) {
            var seen: Set<String> = []
            var queue = target.dependencies.map(dependencyName)
            while let dependency = queue.popLast() {
                guard let dependency else { continue }
                guard seen.insert(dependency).inserted else { continue }
                #expect(!isPositronicDependency(dependency), "\(target.name) reaches PositronicKit through \(dependency).")
                if let dependencyTarget = byName[dependency] {
                    queue.append(contentsOf: dependencyTarget.dependencies.map(dependencyName))
                }
            }
        }
    }

    @Test("no host source imports PositronicKit")
    func sourceImportsAreClean() throws {
        for relativePath in try swiftFiles(in: root) {
            let allowed = Self.transitionalTargets.contains { target in
                relativePath.hasPrefix("Sources/\(target)/")
                    || relativePath.hasPrefix("Tests/\(target)/")
            }
            guard !allowed else { continue }
            let source = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            for module in importedModules(in: source) where isPositronicModule(module) {
                Issue.record("\(relativePath) imports \(module).")
            }
        }
    }

    @Test("the firewall rejects seeded illegal declarations and imports")
    func seededIllegalImportIsDetected() throws {
        let seededPackage = """
        .target(name: "GnosticCore", dependencies: [.product(name: "PKContracts", package: "PositronicKit")]),
        .target(name: "GnosticHost", dependencies: ["PositronicKit"]),
        """
        let seededTargets = try parseTargets(seededPackage)
        #expect(seededTargets.count == 2)
        #expect(seededTargets.allSatisfy { target in
            target.dependencies.contains(where: isPositronicDependency)
        })

        // The seeded source is assembled at runtime so this test file does not
        // itself contain a literal illegal import line.
        let seededCoreSource = [
            "import Foundation",
            "import " + "Positronic" + "Kit",
            "@testable " + "import " + "PK" + "Contracts",
        ].joined(separator: "\n")
        let seededModules = importedModules(in: seededCoreSource)
        #expect(seededModules.contains("PositronicKit"))
        #expect(seededModules.contains("PKContracts"))
    }

    // MARK: - Package parsing

    private struct Target {
        let name: String
        let dependencies: [String]
    }

    private func isAllowed(_ target: String) -> Bool {
        Self.transitionalTargets.contains(target)
    }

    private func isPositronicDependency(_ dependency: String) -> Bool {
        isPositronicModule(dependencyName(dependency) ?? dependency)
    }

    private func isPositronicModule(_ name: String) -> Bool {
        name == "PositronicKit" || name.hasPrefix("PK")
    }

    private func dependencyName(_ dependency: String) -> String? {
        if dependency.hasPrefix(".product(name: \"") {
            return dependency
                .replacingOccurrences(of: ".product(name: \"", with: "")
                .split(separator: "\"")
                .first
                .map(String.init)
        }
        if dependency.hasPrefix("\"") {
            return dependency.trimmingCharacters(in: CharacterSet(charactersIn: "\","))
        }
        return nil
    }

    private func parseTargets(_ package: String) throws -> [Target] {
        let patterns = [".target(", ".executableTarget(", ".testTarget("]
        var starts: [String.Index] = []
        for pattern in patterns {
            var search = package.startIndex
            while let range = package.range(of: pattern, range: search..<package.endIndex) {
                starts.append(range.lowerBound)
                search = range.upperBound
            }
        }
        starts.sort()
        var targets: [Target] = []
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : package.endIndex
            let block = package[start..<end]
            guard let nameRange = block.range(of: "name: \""),
                  let nameEnd = block[nameRange.upperBound...].firstIndex(of: "\"") else { continue }
            let name = String(block[nameRange.upperBound..<nameEnd])
            let dependencies = parseDependencyList(in: block)
            targets.append(Target(name: name, dependencies: dependencies))
        }
        return targets
    }

    private func parseDependencyList(in block: Substring) -> [String] {
        guard let dependenciesStart = block.range(of: "dependencies: [") else { return [] }
        let tail = block[dependenciesStart.upperBound...]
        guard let dependenciesEnd = tail.firstIndex(of: "]") else { return [] }
        let list = tail[..<dependenciesEnd]
        var dependencies: [String] = []
        var current = ""
        var depth = 0
        var inString = false
        for character in list {
            if character == "\"" { inString.toggle() }
            if !inString {
                if character == "(" { depth += 1 }
                if character == ")" { depth -= 1 }
                if character == "," && depth == 0 {
                    appendDependency(current, to: &dependencies)
                    current = ""
                    continue
                }
            }
            current.append(character)
        }
        appendDependency(current, to: &dependencies)
        return dependencies
    }

    private func appendDependency(_ raw: String, to dependencies: inout [String]) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        dependencies.append(trimmed)
    }

    /// The modules one Swift source file imports.
    private func importedModules(in source: String) -> [String] {
        source.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isImport = trimmed.hasPrefix("import ")
                || trimmed.hasPrefix("@testable import ")
                || trimmed.hasPrefix("@_exported import ")
            guard isImport else { return nil }
            return trimmed
                .replacingOccurrences(of: "@testable import ", with: "")
                .replacingOccurrences(of: "@_exported import ", with: "")
                .replacingOccurrences(of: "import ", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
    }

    private func swiftFiles(in root: URL) throws -> [String] {
        var files: [String] = []
        let fileManager = FileManager.default
        for base in ["Sources", "Tests"] {
            let baseURL = root.appendingPathComponent(base)
            guard let enumerator = fileManager.enumerator(atPath: baseURL.path) else { continue }
            for case let relative as String in enumerator where relative.hasSuffix(".swift") {
                files.append("\(base)/\(relative)")
            }
        }
        return files.sorted()
    }
}
