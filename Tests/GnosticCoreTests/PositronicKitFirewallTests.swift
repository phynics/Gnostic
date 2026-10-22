// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

/// The PositronicKit firewall is an architecture test, not a convention.
///
/// PositronicKit runs only in the standalone ACP Runtime process. The host,
/// core, protocol, client, kit, CLI, and frontend targets must not declare it,
/// import it, or reach it through another target's dependency closure.
///
/// The checks are plain functions over parsed data so the seeded cases run
/// through exactly the same code as the repository cases. A check that stops
/// looking therefore fails the seeded test as well.
@Suite("PositronicKit firewall")
struct PositronicKitFirewallTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The targets that may still declare or import a PositronicKit product.
    ///
    /// The list is explicit on purpose. A prefix rule would silently allow a
    /// new target that only looks transitional.
    ///
    /// - `GnosticPositronic*` is the backend family that #611 removes with the
    ///   transitional host composition.
    /// - `GnosticLegacy*` is the isolated transitional composition that #611
    ///   deletes.
    ///
    /// `GnosticPositronicRuntime` is the sole executable permitted to link
    /// PositronicKit. It is intentionally explicit and removed if the runtime
    /// boundary changes.
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
        "GnosticPositronicRuntime",
    ]

    /// The shipped targets the issue names. Each one, and each of its test
    /// targets, must stay free of PositronicKit.
    private static let shippedTargets = [
        "GnosticProtocol",
        "GnosticCore",
        "GnosticClient",
        "GnosticKit",
        "GnosticHost",
        "GnosticCLI",
        "GnosticACPFrontend",
    ]

    /// The standalone Runtime may depend on PositronicKit, but its local ACP
    /// process must not link the Axoloty discovery/routing fabric.
    private static let standaloneRuntimeTarget = "GnosticPositronicRuntime"

    @Test("no target outside the transitional set declares PositronicKit")
    func packageDeclarationsAreClean() throws {
        let package = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        for violation in declarationViolations(package: package) {
            Issue.record(Comment(rawValue: violation))
        }
    }

    @Test("no shipped target reaches PositronicKit through a dependency closure")
    func hostClosuresAreClean() throws {
        let package = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let targets = try parseTargets(package)
        for name in Self.shippedTargets {
            _ = try #require(
                targets.first(where: { $0.name == name }),
                "Package.swift has no target named \(name)."
            )
        }
        for violation in closureViolations(package: package) {
            Issue.record(Comment(rawValue: violation))
        }
    }

    @Test("the standalone Runtime uses ACP wire types without Axoloty")
    func standaloneRuntimeClosureIsIsolated() throws {
        let package = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let targets = try parseTargets(package)
        let byName = Dictionary(uniqueKeysWithValues: targets.map { ($0.name, $0) })
        let runtime = try #require(
            byName[Self.standaloneRuntimeTarget],
            "Package.swift has no standalone PositronicKit Runtime target."
        )
        let reachable = dependencyNames(from: runtime, byName: byName)
        #expect(reachable.contains("GnosticACPWire"))
        #expect(!reachable.contains("GnosticProtocol"))
        #expect(!reachable.contains("Axoloty"))
        #expect(!reachable.contains("AxolotyWire"))
        #expect(!reachable.contains("AxolotyMQTT"))
    }

    @Test("no shipped source imports PositronicKit")
    func sourceImportsAreClean() throws {
        var sources: [String: String] = [:]
        for relativePath in try swiftFiles(in: root) {
            sources[relativePath] = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        }
        for violation in importViolations(sources: sources) {
            Issue.record(Comment(rawValue: violation))
        }
    }

    @Test("the allowance names only targets that exist and still need it")
    func allowanceIsExact() throws {
        let package = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let targets = try parseTargets(package)
        let byName = Dictionary(uniqueKeysWithValues: targets.map { ($0.name, $0) })
        for name in Self.transitionalTargets {
            let target = try #require(
                byName[name],
                "The firewall allows '\(name)', but Package.swift declares no such target."
            )
            #expect(
                reachesPositronic(target: target, byName: byName),
                "The firewall allows '\(name)', but that target no longer reaches PositronicKit."
            )
        }
    }

    @Test("the firewall rejects a seeded illegal declaration, import, and closure")
    func seededViolationsAreDetected() throws {
        // A seeded package: a direct product declaration, a plain target
        // dependency, and a two-step path into the Positronic backend.
        let seededPackage = """
        .target(name: "GnosticCore", dependencies: [.product(name: "PKContracts", package: "PositronicKit")]),
        .target(name: "GnosticHost", dependencies: ["PositronicKit"]),
        .target(name: "GnosticClient", dependencies: ["GnosticClean"]),
        .target(name: "GnosticClean", dependencies: ["GnosticPositronicBackend"]),
        .target(name: "GnosticPositronicBackend", dependencies: [.product(name: "PositronicKit", package: "PositronicKit")]),
        """
        let seededDeclarations = declarationViolations(package: seededPackage)
        #expect(seededDeclarations.contains { $0.contains("GnosticCore") })
        #expect(seededDeclarations.contains { $0.contains("GnosticHost") })

        let seededClosures = closureViolations(package: seededPackage)
        #expect(seededClosures.contains { $0.contains("GnosticClient") })
        #expect(seededClosures.contains { $0.contains("GnosticClean") })

        // A seeded source: an import in the kernel and one in the host, plus a
        // scoped import that names a type from the package.
        let seededSources = [
            "Sources/GnosticCore/Seeded.swift": "import Foundation\nimport PositronicKit\n",
            "Sources/GnosticHost/Seeded.swift": "import PKContracts\n",
            "Sources/GnosticClient/Seeded.swift": "import class PositronicKit.SomeType\n",
        ]
        let seededImports = importViolations(sources: seededSources)
        #expect(seededImports.contains { $0.contains("Sources/GnosticCore/Seeded.swift") })
        #expect(seededImports.contains { $0.contains("Sources/GnosticHost/Seeded.swift") })
        #expect(seededImports.contains { $0.contains("Sources/GnosticClient/Seeded.swift") })
    }

    // MARK: - Checks

    /// Reports every target that declares a PositronicKit product outside the
    /// transitional set.
    private func declarationViolations(package: String) -> [String] {
        guard let targets = try? parseTargets(package) else { return [] }
        var violations: [String] = []
        for target in targets where !isAllowed(target.name) {
            for dependency in target.dependencies where isPositronicDependency(dependency) {
                violations.append("Target \(target.name) declares PositronicKit dependency \(dependency).")
            }
        }
        return violations
    }

    /// Reports every non-transitional target that reaches PositronicKit
    /// through its dependency closure.
    private func closureViolations(package: String) -> [String] {
        guard let targets = try? parseTargets(package) else { return [] }
        let byName = Dictionary(uniqueKeysWithValues: targets.map { ($0.name, $0) })
        var violations: [String] = []
        for target in targets where !isAllowed(target.name) {
            var seen: Set<String> = []
            var queue = target.dependencies.map(dependencyName)
            while let dependency = queue.popLast() {
                guard let dependency else { continue }
                guard seen.insert(dependency).inserted else { continue }
                if isPositronicDependency(dependency) {
                    violations.append("\(target.name) reaches PositronicKit through \(dependency).")
                    continue
                }
                if let dependencyTarget = byName[dependency] {
                    queue.append(contentsOf: dependencyTarget.dependencies.map(dependencyName))
                }
            }
        }
        return violations
    }

    /// Reports every shipped source file that imports a PositronicKit product.
    private func importViolations(sources: [String: String]) -> [String] {
        var violations: [String] = []
        for (relativePath, source) in sources.sorted(by: { $0.key < $1.key }) {
            let allowed = Self.transitionalTargets.contains { target in
                relativePath.hasPrefix("Sources/\(target)/")
                    || relativePath.hasPrefix("Tests/\(target)/")
            }
            guard !allowed else { continue }
            for module in importedModules(in: source) where isPositronicModule(module) {
                violations.append("\(relativePath) imports \(module).")
            }
        }
        return violations
    }

    /// Whether one target reaches a PositronicKit product.
    private func reachesPositronic(target: Target, byName: [String: Target]) -> Bool {
        var seen: Set<String> = []
        var queue = target.dependencies.map(dependencyName)
        while let dependency = queue.popLast() {
            guard let dependency else { continue }
            guard seen.insert(dependency).inserted else { continue }
            if isPositronicDependency(dependency) { return true }
            if let dependencyTarget = byName[dependency] {
                queue.append(contentsOf: dependencyTarget.dependencies.map(dependencyName))
            }
        }
        return false
    }

    private func dependencyNames(from target: Target, byName: [String: Target]) -> Set<String> {
        var seen: Set<String> = []
        var queue = target.dependencies.map(dependencyName)
        while let dependency = queue.popLast() {
            guard let dependency, seen.insert(dependency).inserted else { continue }
            if let dependencyTarget = byName[dependency] {
                queue.append(contentsOf: dependencyTarget.dependencies.map(dependencyName))
            }
        }
        return seen
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

    /// Whether one module name names a PositronicKit product.
    ///
    /// A scoped import such as `import class PositronicKit.SomeType` names the
    /// package as its root.
    private func isPositronicModule(_ name: String) -> Bool {
        let root = name.split(separator: ".").first.map(String.init) ?? name
        return root == "PositronicKit" || root.hasPrefix("PK")
    }

    private func dependencyName(_ dependency: String) -> String? {
        if dependency.hasPrefix(".product(") {
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

    // MARK: - Source parsing

    /// The modules one Swift source file imports.
    private func importedModules(in source: String) -> [String] {
        source.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isImport = trimmed.hasPrefix("import ")
                || trimmed.hasPrefix("@testable import ")
                || trimmed.hasPrefix("@_exported import ")
            guard isImport else { return nil }
            var module = trimmed
                .replacingOccurrences(of: "@testable ", with: "")
                .replacingOccurrences(of: "@_exported ", with: "")
                .replacingOccurrences(of: "import ", with: "")
                .trimmingCharacters(in: .whitespaces)
            for kind in ["class ", "struct ", "enum ", "typealias ", "protocol ", "func ", "var ", "let "] {
                if module.hasPrefix(kind) {
                    module = String(module.dropFirst(kind.count))
                    break
                }
            }
            return module
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
