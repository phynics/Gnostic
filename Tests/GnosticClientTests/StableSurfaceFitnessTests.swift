// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

/// Architecture fitness for the stable products `GnosticProtocol` and
/// `GnosticClient` (owner decisions D13 and D19 on #551, issues #675 and #676).
///
/// The checks read the committed public API baseline in
/// `Documentation/Compatibility/API/`. The compiler wrote that text, and
/// `make api-check` (part of `make verify`) fails when it differs from the
/// current build. So these rules cover every public declaration the compiler
/// exports: a multi-line `public typealias`, a member of a `public extension`,
/// and an `@_exported import` all appear in the baseline. A source scan misses
/// all three.
@Suite("Stable surface fitness")
struct StableSurfaceFitnessTests {
    private static let products = ["GnosticProtocol", "GnosticClient"]

    /// Public reference types that stay in a stable product (owner decision
    /// D29 on #551, issue #717). Each entry needs a reason, and
    /// `Documentation/Compatibility/0.5.0.md` repeats the list. A data type is
    /// never an exception: it is an immutable `Sendable` value.
    static let deliberateReferenceTypes: [String: String] = {
        let reason = "A `@MainActor final` service handle, not data. It has no public settable property, and actor isolation makes its Sendable conformance checked."
        return [
            "GnosticConsumerSession": reason,
            "GnosticDiagnosticsClient": reason,
            "GnosticTimelineClient": reason,
            "GnosticTurnClient": reason,
            "GnosticWorkspaceClient": reason,
        ]
    }()

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func baselineLines(of product: String) throws -> [String] {
        let url = root.appendingPathComponent("Documentation/Compatibility/API/\(product).swiftinterface")
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    @Test("each baseline holds public declarations")
    func baselinesAreNotEmpty() throws {
        for product in Self.products {
            let publicLines = try Self.baselineLines(of: product).filter { $0.contains("public ") }
            #expect(publicLines.count > 10, "The \(product) baseline lists no public API; regenerate it with `make api-update`.")
        }
    }

    @Test("no public symbol of GnosticProtocol or GnosticClient is named Ascendant")
    func noAscendantNames() throws {
        for product in Self.products {
            let named = try Self.baselineLines(of: product).filter { $0.lowercased().contains("ascendant") }
            #expect(named.isEmpty, "Stable products must not name Ascendant (D13): \(named)")
        }
    }

    @Test("no GnosticCore type appears in the public API of GnosticClient or GnosticProtocol")
    func noCoreTypeInPublicAPI() throws {
        for product in Self.products {
            // `import GnosticCore` is an implementation import. A type of the
            // module prints as `GnosticCore::Name` wherever a signature uses it.
            let leaked = try Self.baselineLines(of: product).filter { $0.contains("GnosticCore::") }
            #expect(leaked.isEmpty, "GnosticCore types leak into \(product)'s public API (D13): \(leaked)")
        }
    }

    @Test("GnosticProtocol publishes no ACP typealias")
    func protocolPublishesNoACPAlias() throws {
        let aliases = try Self.baselineLines(of: "GnosticProtocol").filter { $0.contains("typealias ACP") }
        #expect(aliases.isEmpty, "D19 removed the ACP typealiases; import GnosticACPWire instead: \(aliases)")
    }

    @Test("no ACP wire type appears in a stable signature (D27)")
    func noACPTypeInStableSignatures() throws {
        for product in Self.products {
            let leaked = try Self.baselineLines(of: product).filter { $0.contains("GnosticACPWire::") }
            #expect(leaked.isEmpty, "A preview ACP type is in \(product)'s public API (D27): \(leaked)")
        }
    }

    @Test("no open class and no unchecked Sendable type is public, apart from listed exceptions (D29)")
    func noMutableReferenceOrUncheckedSendableInBaselines() throws {
        var declared: Set<String> = []
        for product in Self.products {
            for line in try Self.baselineLines(of: product) {
                let words = line.split(separator: " ").map(String.init)
                #expect(!words.contains("open"), "An open declaration is public in \(product) (D29): \(line)")
                #expect(!line.contains("@unchecked"), "An unchecked Sendable type is public in \(product) (D29): \(line)")
                guard let index = words.firstIndex(of: "class"), index > 0, index + 1 < words.count,
                      ["public", "open"].contains(words[index - 1]) else { continue }
                // `class var` and `class func` are members. A type has a name.
                let name = words[index + 1]
                guard !["var", "let", "func", "init", "subscript"].contains(name) else { continue }
                declared.insert(name)
                #expect(
                    Self.deliberateReferenceTypes[name] != nil,
                    "\(name) is a public reference type in \(product) without a listed exception (D29): \(line)"
                )
                #expect(words.contains("final"), "\(name) is a public class that is not final (D29): \(line)")
            }
        }
        for name in Self.deliberateReferenceTypes.keys {
            #expect(declared.contains(name), "\(name) is listed as a reference-type exception but is not public any more; remove it.")
        }
    }

    @Test("no public property of a stable product is settable (D29)")
    func noSettablePublicProperty() throws {
        for product in Self.products {
            for line in try Self.baselineLines(of: product) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // A stored `var` prints without a body. A computed one prints `{`
                // and a `set` accessor on its own line.
                let storedVar = trimmed.range(of: #"\bpublic (?:static )?var [^{]*$"#, options: .regularExpression) != nil
                let setter = trimmed == "set" || trimmed.hasSuffix(" set")
                #expect(!storedVar && !setter, "A settable public property is in \(product) (D29): \(line)")
            }
        }
    }

    @Test("the Coaty object model and the Gnostic*Object transport classes are not public (D29)")
    func transportObjectsStayOutOfTheBaseline() throws {
        let names = [
            "CoatyObject", "CoatyUUID", "CoreType", "GnosticRuntimeInstanceObject",
            "GnosticTimelineObject", "GnosticWorkspaceObject", "GnosticWorkspaceToolObject",
        ]
        for product in Self.products {
            let lines = try Self.baselineLines(of: product)
            for name in names {
                let named = lines.filter { $0.contains(name) }
                #expect(named.isEmpty, "\(name) is a mutable transport type and must stay out of \(product) (D29): \(named)")
            }
        }
    }

    @Test("the D28 wire plumbing and Core records are not public")
    func trimmedSymbolsStayOutOfTheBaseline() throws {
        let declarations = [
            "RuntimeInstanceIdentity", "RuntimeInstanceCapabilities", "RuntimeInstanceTimeline",
            "GnosticPublicFailure", "TurnError", "TurnSessionUpdate", "ManifestJSONValue",
        ]
        let members = [
            "decodeMajor", "boundedStatusCode", "failureMessage", "validatePayload", "validateEvent",
            "boundedLabel", "boundedIdentifier", "boundedWorkspaceIDs", "targeted(to", "privateTimelineID",
            "primaryWorkspaceID", "backendKind", "backendVersion", "runtimeThread", "from(stopReason",
            "static func register(", "static func prefix(", "static func encode<",
            "var custom:", "var runtimeID:",
        ]
        for product in Self.products {
            let lines = try Self.baselineLines(of: product)
            for name in declarations {
                let named = lines.filter { Self.declares(name, in: $0) }
                #expect(named.isEmpty, "\(name) must not be public in \(product) (D28): \(named)")
            }
            for member in members {
                let named = lines.filter { $0.contains(member) }
                #expect(named.isEmpty, "\(member) must not be public in \(product) (D27, D28): \(named)")
            }
        }
    }

    @Test("0.5.0.md lists every public GnosticProtocol enum with a raw value as frozen or open (D30)")
    func enumPolicyCoversEveryRawValueEnum() throws {
        // A nested enum is named `Parent.Child`, as the policy table writes it.
        var parent = ""
        var enums: [String] = []
        for line in try Self.baselineLines(of: "GnosticProtocol") {
            let indented = line.hasPrefix(" ")
            let words = line.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
            guard let publicIndex = words.firstIndex(of: "public"), words.count > publicIndex + 2 else { continue }
            let keyword = words[publicIndex + 1]
            guard ["struct", "enum", "class"].contains(keyword) else { continue }
            let name = words[publicIndex + 2].trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            if !indented { parent = name }
            if keyword == "enum", line.contains(": Swift::String") {
                enums.append(indented ? "\(parent).\(name)" : name)
            }
        }
        #expect(enums.count >= 8, "The scan found too few raw-value enums: \(enums)")
        let declaration = try String(
            contentsOf: Self.root.appendingPathComponent("Documentation/Compatibility/0.5.0.md"),
            encoding: .utf8
        )
        let rows = declaration.split(separator: "\n").filter { $0.hasPrefix("| `") }
        for name in enums {
            let row = rows.first { $0.hasPrefix("| `\(name)` |") }
            #expect(row != nil, "\(name) is missing from the enum policy table in 0.5.0.md (D30).")
            #expect(
                row.map { $0.contains("| Frozen |") || $0.contains("| Open |") } ?? false,
                "\(name) must be Frozen or Open in the enum policy table."
            )
        }
    }

    /// Whether a baseline line declares a type of this name.
    private static func declares(_ name: String, in line: String) -> Bool {
        for keyword in ["struct", "enum", "class"] where line.contains(" \(keyword) \(name) ") || line.contains(" \(keyword) \(name):") {
            return true
        }
        return false
    }
}
