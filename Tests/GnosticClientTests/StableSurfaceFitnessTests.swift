// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

/// Architecture fitness for the stable products `GnosticProtocol` and
/// `GnosticClient` (owner decisions D13 and D19 on #551, issue #675).
///
/// The checks read the source files, so they fail when a declaration is added,
/// not when a build happens to link.
@Suite("Stable surface fitness")
struct StableSurfaceFitnessTests {
    private struct Source {
        let path: String
        let code: String
    }

    private struct Declaration {
        let path: String
        let text: String
        let isPublic: Bool
        let isPrivate: Bool
    }

    /// Declarations whose name may keep "Ascendant" in a stable product. Each
    /// entry needs the owning issue and a reconsideration condition in
    /// `Documentation/Compatibility/0.5.0.md`. The list is empty: D20 keeps the
    /// CLI `ascendant` commands and `NodeManifest.Ascendant`, and neither is in
    /// a stable product.
    private static let deliberateAscendantExceptions: Set<String> = []

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("no symbol that GnosticProtocol or GnosticClient declares is named Ascendant")
    func noAscendantNames() throws {
        var violations: [String] = []
        for target in ["GnosticProtocol", "GnosticClient"] {
            for declaration in try Self.declarations(in: "Sources/\(target)") where !declaration.isPrivate {
                let named = Self.introducedNames(in: declaration.text)
                    .filter { $0.lowercased().contains("ascendant") }
                    .filter { !Self.deliberateAscendantExceptions.contains($0) }
                if !named.isEmpty {
                    violations.append("\(declaration.path): \(named) in \(declaration.text.prefix(120))")
                }
            }
        }
        #expect(violations.isEmpty, "Stable products must not name Ascendant (D13): \(violations)")
    }

    @Test("no GnosticCore type appears in a public GnosticClient signature")
    func noCoreTypeInClientSignatures() throws {
        let coreTypes = try Self.publicTypeNames(in: "Sources/GnosticCore")
            .subtracting(Self.publicTypeNames(in: "Sources/GnosticProtocol"))
            .subtracting(Self.publicTypeNames(in: "Sources/GnosticClient"))
        #expect(!coreTypes.isEmpty, "The scan found no GnosticCore types to check against.")

        var violations: [String] = []
        for declaration in try Self.declarations(in: "Sources/GnosticClient") where declaration.isPublic {
            let identifiers = Set(Self.identifiers(in: declaration.text))
            let leaked = identifiers.intersection(coreTypes)
            if !leaked.isEmpty {
                violations.append("\(declaration.path): \(leaked.sorted()) in \(declaration.text.prefix(120))")
            }
        }
        #expect(violations.isEmpty, "GnosticCore types leak into GnosticClient's public API (D13): \(violations)")
    }

    @Test("GnosticProtocol publishes no ACP typealias")
    func protocolPublishesNoACPAlias() throws {
        let aliases = try Self.declarations(in: "Sources/GnosticProtocol")
            .filter { $0.isPublic && $0.text.contains("typealias ACP") }
        #expect(aliases.isEmpty, "D19 removed the ACP typealiases; import GnosticACPWire instead: \(aliases.map(\.path))")
    }

    // MARK: - Source scanning

    private static func sources(in relativePath: String) throws -> [Source] {
        let sourceRoot = root.appendingPathComponent(relativePath)
        return try FileManager.default.subpathsOfDirectory(atPath: sourceRoot.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
            .map { path in
                let text = try String(contentsOf: sourceRoot.appendingPathComponent(path), encoding: .utf8)
                return Source(path: "\(relativePath)/\(path)", code: stripCommentsAndStrings(text))
            }
    }

    /// Removes `//` comments and the content of string literals, so a doc
    /// comment or a wire string never counts as a declaration.
    private static func stripCommentsAndStrings(_ text: String) -> String {
        var output = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var kept = ""
            var inString = false
            var previous: Character?
            for character in line {
                if !inString, character == "/", previous == "/" {
                    kept.removeLast()
                    break
                }
                if character == "\"", previous != "\\" { inString.toggle() }
                if !inString || character == "\"" { kept.append(character) }
                previous = character
            }
            output += kept + "\n"
        }
        return output
    }

    private static let declarationStart = try! NSRegularExpression(
        pattern: #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|open|package|internal|private|fileprivate|final|static|class|indirect|nonisolated|override|required|convenience|mutating|lazy|weak)\s+)*(?:func|var|let|case|struct|class|enum|actor|protocol|typealias|init|subscript)\b"#
    )

    /// Collects each declaration head: from its keyword to the end of its
    /// parameter list, so a label on a later line still belongs to it.
    private static func declarations(in relativePath: String) throws -> [Declaration] {
        var result: [Declaration] = []
        for source in try sources(in: relativePath) {
            let lines = source.code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var index = 0
            while index < lines.count {
                let line = lines[index]
                let range = NSRange(line.startIndex..., in: line)
                guard declarationStart.firstMatch(in: line, range: range) != nil else {
                    index += 1
                    continue
                }
                var text = line
                var depth = line.filter { $0 == "(" }.count - line.filter { $0 == ")" }.count
                while depth > 0, index + 1 < lines.count {
                    index += 1
                    text += " " + lines[index].trimmingCharacters(in: .whitespaces)
                    depth += lines[index].filter { $0 == "(" }.count - lines[index].filter { $0 == ")" }.count
                }
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                let isPublic = trimmed.hasPrefix("public ") || trimmed.hasPrefix("open ")
                    || trimmed.range(of: #"^(?:@\w+\s+)+public "#, options: .regularExpression) != nil
                let isPrivate = trimmed.range(of: #"\b(?:private|fileprivate)\b"#, options: .regularExpression) != nil
                result.append(Declaration(path: source.path, text: trimmed, isPublic: isPublic, isPrivate: isPrivate))
                index += 1
            }
        }
        return result
    }

    private static func publicTypeNames(in relativePath: String) throws -> Set<String> {
        let pattern = try NSRegularExpression(
            pattern: #"^\s*(?:@\w+\s+)*public\s+(?:final\s+|indirect\s+)*(?:struct|class|enum|actor|protocol|typealias)\s+([A-Z]\w*)"#,
            options: [.anchorsMatchLines]
        )
        var names: Set<String> = []
        for source in try sources(in: relativePath) {
            let range = NSRange(source.code.startIndex..., in: source.code)
            for match in pattern.matches(in: source.code, range: range) {
                if let nameRange = Range(match.range(at: 1), in: source.code) {
                    names.insert(String(source.code[nameRange]))
                }
            }
        }
        return names
    }

    /// The names a declaration introduces: its own name and its parameter and
    /// associated-value labels. A type mentioned in a signature is not
    /// introduced by it.
    private static func introducedNames(in text: String) -> [String] {
        var names: [String] = []
        let head = try! NSRegularExpression(pattern: #"\b(?:func|var|let|case|struct|class|enum|actor|protocol|typealias|extension)\s+`?([A-Za-z_]\w*)"#)
        let fullRange = NSRange(text.startIndex..., in: text)
        if let match = head.firstMatch(in: text, range: fullRange), let range = Range(match.range(at: 1), in: text) {
            names.append(String(text[range]))
        }
        guard let open = text.firstIndex(of: "(") else { return names }
        let labels = try! NSRegularExpression(pattern: #"[(,]\s*(?:_\s+)?([A-Za-z_]\w*)(?:\s+([A-Za-z_]\w*))?\s*:"#)
        let tail = String(text[open...])
        for match in labels.matches(in: tail, range: NSRange(tail.startIndex..., in: tail)) {
            for group in 1...2 {
                if let range = Range(match.range(at: group), in: tail) { names.append(String(tail[range])) }
            }
        }
        return names
    }

    private static func identifiers(in text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"\b[A-Z]\w*"#)
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }
}
