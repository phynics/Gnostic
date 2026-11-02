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
            let lines = try Self.baselineLines(of: product)
            for line in lines {
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
                // The reason on the list is true only while actor isolation holds
                // the class and the compiler checks its Sendable conformance.
                #expect(
                    words.contains("@_Concurrency::MainActor"),
                    "\(name) is listed as a `@MainActor final` handle but is not `@MainActor` in \(product) (D29): \(line)"
                )
                #expect(
                    lines.contains { $0.trimmingCharacters(in: .whitespaces) == "extension \(product)::\(name) : Swift::Sendable {}" },
                    "\(name) has no checked `Sendable` conformance in \(product) (D29)."
                )
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

    @Test("no baseline names a Gnostic capability or a capability failure (D31)")
    func capabilityNamesStayOutOfTheBaseline() throws {
        let names = ["InteroperabilityCapability", "GnosticCapability", "missingCapability", "providedByRuntimeInstance"]
        for product in Self.products {
            let lines = try Self.baselineLines(of: product)
            for name in names {
                let named = lines.filter { $0.contains(name) }
                #expect(named.isEmpty, "\(name) was removed by D31 and must stay out of \(product): \(named)")
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

    @Test("0.5.0.md classifies every public case-bearing enum, and a Frozen row lists the baseline's cases (D30, D34)")
    func enumPolicyMatchesTheBaselines() throws {
        let baselines = try Self.products.map { try Self.baselineLines(of: $0) }
        let problems = Self.enumPolicyProblems(baselines: baselines, declaration: try Self.declaration())
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test("the enum policy scan reads names and cases from the baselines")
    func enumPolicyScanFindsTheEnums() throws {
        let enums = try Self.products.flatMap { try Self.publicEnums(in: Self.baselineLines(of: $0)) }
        let names = Set(enums.map(\.name))
        for name in [
            "GnosticRuntimeInstanceHealth", "NetworkDynamicValue", "Project.Kind", "GnosticWirePayload.Error",
            "GnosticTurnClientError", "GnosticJSONValue", "WorkspaceAttachmentStatus", "GnosticRawWireEventKind",
        ] {
            #expect(names.contains(name), "The scan did not find \(name): \(names.sorted())")
        }
        #expect(enums.contains { $0.name == "GnosticRuntimeInstanceHealth" && $0.cases.contains("healthy") })
        #expect(enums.contains { $0.name == "Project.Kind" && $0.cases == ["local", "scratch"] })
        #expect(enums.contains { $0.name == "GnosticWirePayload" && $0.cases.isEmpty })
        #expect(enums.contains { $0.name == "GnosticWirePayload.Error" && $0.isError && $0.cases.count == 2 })
    }

    @Test("the enum policy check fails when a Frozen enum gains a case")
    func enumPolicyCatchesAnAddedCase() throws {
        let baselines = try Self.products.map { try Self.baselineLines(of: $0) }.map { lines in
            lines.flatMap { line -> [String] in
                line.hasPrefix("public enum GnosticRuntimeInstanceHealth") ? [line, "  case degraded"] : [line]
            }
        }
        let problems = Self.enumPolicyProblems(baselines: baselines, declaration: try Self.declaration())
        #expect(problems.contains { $0.contains("GnosticRuntimeInstanceHealth") && $0.contains("degraded") }, "\(problems)")
    }

    @Test("the enum policy check fails when a Frozen enum loses a case")
    func enumPolicyCatchesARemovedCase() throws {
        let baselines = try Self.products.map { try Self.baselineLines(of: $0) }.map { lines in
            lines.filter { $0 != "  case providerEvicted(Swift::String)" }
        }
        let problems = Self.enumPolicyProblems(baselines: baselines, declaration: try Self.declaration())
        #expect(problems.contains { $0.contains("NetworkCatalogChange") && $0.contains("providerEvicted") }, "\(problems)")
    }

    @Test("the enum policy check fails when a table row is missing")
    func enumPolicyCatchesAMissingRow() throws {
        let baselines = try Self.products.map { try Self.baselineLines(of: $0) }
        let declaration = try Self.declaration().split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("| `WorkspaceAttachmentStatus` |") }.joined(separator: "\n")
        let problems = Self.enumPolicyProblems(baselines: baselines, declaration: declaration)
        #expect(problems.contains { $0.contains("WorkspaceAttachmentStatus") && $0.contains("not classified") }, "\(problems)")
    }

    @Test("the enum policy check fails for a new enum and for an error enum missing from the unfrozen list")
    func enumPolicyCatchesAnUnclassifiedEnum() throws {
        var baselines = try Self.products.map { try Self.baselineLines(of: $0) }
        baselines[0] += ["public enum GnosticBrandNewMode : Swift::Sendable {", "  case one", "}"]
        baselines[0] += ["public enum GnosticBrandNewError : Swift::Error, Swift::Sendable {", "  case broken", "}"]
        let problems = Self.enumPolicyProblems(baselines: baselines, declaration: try Self.declaration())
        #expect(problems.contains { $0.contains("GnosticBrandNewMode") && $0.contains("not classified") }, "\(problems)")
        #expect(problems.contains { $0.contains("GnosticBrandNewError") && $0.contains("not classified") }, "\(problems)")
    }

    @Test("the enum policy check sees indirect and backtick-escaped cases")
    func enumPolicyCatchesUnusualCaseSyntax() throws {
        let baselines = try Self.products.map { try Self.baselineLines(of: $0) }.map { lines in
            lines.flatMap { line -> [String] in
                line.hasPrefix("public enum NetworkCatalogChange")
                    ? [line, "  indirect case recursive(GnosticProtocol::NetworkCatalogChange)", "  case `default`"]
                    : [line]
            }
        }
        let problems = Self.enumPolicyProblems(baselines: baselines, declaration: try Self.declaration())
        #expect(problems.contains { $0.contains("NetworkCatalogChange") && $0.contains("recursive") }, "\(problems)")
        #expect(problems.contains { $0.contains("NetworkCatalogChange") && $0.contains("default") }, "\(problems)")
    }

    @Test("the enum policy check does not let a nested enum borrow another enum's row")
    func enumPolicyCatchesANestedEnumWithABorrowedName() throws {
        let baselines = try Self.products.map { try Self.baselineLines(of: $0) }.map { lines in
            lines.flatMap { line -> [String] in
                line.hasPrefix("public struct Project :") ? [
                    line, "  public struct Extra {", "    public enum Kind {",
                    "      case local", "      case scratch", "    }", "  }",
                ] : [line]
            }
        }
        let problems = Self.enumPolicyProblems(baselines: baselines, declaration: try Self.declaration())
        #expect(problems.contains { $0.contains("Project.Extra.Kind") && $0.contains("not classified") }, "\(problems)")
    }

    @Test("the enum scan names an enum by its full nominal or extension scope")
    func enumScanTracksFullScope() {
        let enums = Self.publicEnums(in: [
            "public struct Unrelated {", "  public func body() -> Swift::Int {", "    switch self {", "    case .a: return 1",
            "    }", "  }", "}",
            "extension GnosticProtocol::Carrier.Inner : Swift::Sendable {", "  public enum Mode {", "    case on",
            "    public var name: Swift::String {", "      switch self {", "      case .on: return \"{\"", "      }", "    }",
            "  }", "}",
            "@frozen indirect public enum Tree {", "  case leaf", "  indirect case node(left: Tree, right: Tree), `default`", "}",
            "public struct Generic<T>", "  where T : Swift::Sendable", "{", "  public enum Nested {", "    case one", "  }", "}",
        ])
        #expect(enums.map(\.name) == ["Carrier.Inner.Mode", "Tree", "Generic.Nested"])
        #expect(enums.first { $0.name == "Carrier.Inner.Mode" }?.cases == ["on"])
        #expect(enums.first { $0.name == "Tree" }?.cases == ["leaf", "node", "default"])
    }

    @Test("text in an inlinable body does not hide a later enum")
    func enumScanIgnoresTextInBodies() {
        let bodies = [
            #"@inlinable public func f() -> Swift::String { "\\" }"#,
            #"@inlinable public func f() -> Swift::String { "\"{" }"#,
            ##"@inlinable public func f() -> Swift::String { #"\"# }"##,
            #"@inlinable public func f() -> Swift::String { "\("{")" }"#,
            #"@inlinable public func f() -> Swift::String { "\("}")" }"#,
            "@inlinable public func f() -> Regex<Substring> { #/\\{/# }",
            "@inlinable public func f() -> Regex<Substring> { #/\\}/# }",
            "@inlinable public func f() { /* { */ } // {",
        ]
        for body in bodies {
            let enums = Self.publicEnums(in: [
                "public struct Carrier {", "  \(body)", "  public enum Probe {", "    \(body)", "    case one", "  }", "}",
                "public enum After {", "  case two", "}",
            ])
            #expect(enums.map(\.name) == ["Carrier.Probe", "After"], "\(body)")
            #expect(enums.first?.cases == ["one"], "\(body)")
        }
    }

    @Test("every legal case name counts, including an emoji")
    func enumScanReadsEveryCaseName() throws {
        let enums = Self.publicEnums(in: ["public enum Pet {", "  case 🐈", "  case 犬(Swift::String), `default`", "}"])
        #expect(enums.first?.cases == ["🐈", "犬", "default"])
        let baselines = try Self.products.map { try Self.baselineLines(of: $0) }.map { lines in
            lines.flatMap { line -> [String] in
                line.hasPrefix("public enum GnosticRuntimeInstanceHealth") ? [line, "  case 🐈"] : [line]
            }
        }
        let problems = Self.enumPolicyProblems(baselines: baselines, declaration: try Self.declaration())
        #expect(problems.contains { $0.contains("GnosticRuntimeInstanceHealth") && $0.contains("🐈") }, "\(problems)")
    }

    @Test("every component of an extension target is part of the enum's name, and names do not repeat parents")
    func enumScanQualifiesNestedScopes() {
        let enums = Self.publicEnums(in: [
            "extension GnosticProtocol::Carrier.GnosticProtocol::Project {", "  public enum Kind {", "    case local", "  }", "}",
            "public struct Project {", "  public struct Extra {", "    public enum Kind {", "      case local", "    }", "  }", "}",
        ])
        #expect(enums.map(\.name) == ["Carrier.Project.Kind", "Project.Extra.Kind"])
    }

    private static func declaration() throws -> String {
        try String(
            contentsOf: root.appendingPathComponent("Documentation/Compatibility/0.5.0.md"),
            encoding: .utf8
        )
    }

    /// A public enum read from a baseline. A nested enum has its full scope in
    /// its name, such as `Project.Kind`, as the policy table writes it. A namespace
    /// has no cases.
    struct BaselineEnum {
        var name: String
        var isError: Bool
        var cases: [String] = []
    }

    /// Enums with an owner decision that is not a table row. `GnosticJSONValue`
    /// follows the JSON data model and does not change; the enum policy section
    /// says so, and `enumPolicyProblems` fails if that sentence goes away.
    private static let namedExemptions: Set<String> = ["GnosticJSONValue"]

    /// A type or extension declaration read from one baseline line.
    private struct BaselineDeclaration {
        var name: String
        var isExtension: Bool
        var isPublicEnum: Bool
        var isError: Bool
    }

    /// Reads every public enum, with its cases, from baseline lines.
    ///
    /// Structure comes from the compiler's layout, not from parsing code: it prints
    /// each declaration on its own line and indents members by two spaces. Inlinable
    /// bodies hold arbitrary text, such as strings and regex literals, and reading
    /// their braces can hide an enum. A line that looks like a public enum always
    /// counts, so an odd body can only make this check fail, never pass.
    static func publicEnums(in lines: [String]) -> [BaselineEnum] {
        var found: [BaselineEnum] = []
        var scopes: [(indent: Int, name: String, enumIndex: Int?)] = []
        for line in lines {
            let indent = line.prefix { $0 == " " }.count
            let text = droppingLeadingAttributes(line.trimmingCharacters(in: .whitespaces))
            guard !text.isEmpty else { continue }
            if text.hasPrefix("}") {
                while let last = scopes.last, last.indent >= indent { scopes.removeLast() }
                continue
            }
            if let last = scopes.last, let enumIndex = last.enumIndex, indent == last.indent + 2,
               let cases = caseClause(of: text) {
                found[enumIndex].cases += caseNames(in: cases)
                continue
            }
            guard let declaration = declaration(in: text) else { continue }
            while let last = scopes.last, last.indent >= indent { scopes.removeLast() }
            let name = declaration.isExtension || scopes.isEmpty
                ? declaration.name
                : "\(scopes[scopes.count - 1].name).\(declaration.name)"
            var enumIndex: Int?
            if declaration.isPublicEnum {
                found.append(BaselineEnum(name: name, isError: declaration.isError))
                enumIndex = found.count - 1
            }
            if !text.hasSuffix("}") { scopes.append((indent, name, enumIndex)) }
        }
        return found
    }

    /// Reads a type or extension declaration. Modifiers can stand in any order
    /// before the keyword, as in `indirect public enum`.
    private static func declaration(in text: String) -> BaselineDeclaration? {
        let words = text.split(separator: " ").map(String.init)
        let modifiers: Set<String> = [
            "public", "open", "package", "internal", "final", "indirect", "nonisolated", "distributed",
        ]
        let keywords: Set<String> = ["struct", "class", "actor", "enum", "protocol", "extension"]
        guard let keyword = words.firstIndex(where: { !modifiers.contains($0) && !$0.hasPrefix("@") }),
              keywords.contains(words[keyword]), words.count > keyword + 1 else { return nil }
        let target = words[keyword + 1]
        guard !["func", "var", "let", "subscript", "init"].contains(target) else { return nil }
        // Every component of a target can carry a module selector, as in
        // `Module::Carrier.Module::Project`.
        let name = target.prefix { $0 != "<" && $0 != "{" }.split(separator: ".").map { component in
            (component.components(separatedBy: "::").last ?? String(component))
                .trimmingCharacters(in: CharacterSet(charactersIn: ":`"))
        }.joined(separator: ".")
        return BaselineDeclaration(
            name: name,
            isExtension: words[keyword] == "extension",
            isPublicEnum: words[keyword] == "enum" && words[..<keyword].contains("public"),
            isError: text.contains("Swift::Error") || text.contains("Swift.Error")
        )
    }

    /// Removes attributes in front of a declaration, such as `@frozen` or
    /// `@available(macOS 10.15, *)`.
    private static func droppingLeadingAttributes(_ text: String) -> String {
        var rest = Substring(text)
        while rest.hasPrefix("@") {
            let word = rest.prefix { $0 != " " && $0 != "(" }
            rest = rest.dropFirst(word.count)
            if rest.hasPrefix("(") {
                var depth = 0
                while let character = rest.first {
                    if character == "(" { depth += 1 }
                    if character == ")" { depth -= 1 }
                    rest = rest.dropFirst()
                    if depth == 0 { break }
                }
            }
            rest = rest.drop { $0 == " " }
        }
        return String(rest)
    }

    /// What follows `case` or `indirect case`, or nil for any other line.
    private static func caseClause(of text: String) -> String? {
        for prefix in ["case ", "indirect case "] where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count))
        }
        return nil
    }

    /// The case names of one `case` line: `a`, `a(Type)`, `a(x: X, y: Y)`, `a, b`,
    /// or `` `default` ``. Only a comma outside parentheses separates two cases.
    private static func caseNames(in declaration: String) -> [String] {
        var pieces: [String] = [""]
        var depth = 0
        for character in declaration {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            if character == ",", depth == 0 {
                pieces.append("")
            } else {
                pieces[pieces.count - 1].append(character)
            }
        }
        return pieces.compactMap { piece in
            let name = piece.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "`", with: "")
                .prefix { !" (:=".contains($0) }
            return name.isEmpty ? nil : String(name)
        }
    }

    /// The backtick-quoted words in a piece of Markdown.
    private static func backticked(_ text: String) -> [String] {
        text.split(separator: "`", omittingEmptySubsequences: false).enumerated()
            .filter { $0.offset % 2 == 1 }.map { String($0.element) }
    }

    /// Checks the enum policy in `0.5.0.md` against the enums in the stable
    /// baselines. Every problem names its enum.
    ///
    /// - A public enum with cases is a table row, an entry of the unfrozen error
    ///   list, or a named exemption. An enum with no cases is a namespace.
    /// - An enum that conforms to `Error` is on the unfrozen list (D34).
    /// - A Frozen row lists exactly the baseline's cases (D30).
    /// - A row or list entry names an enum that is in a baseline.
    static func enumPolicyProblems(baselines: [[String]], declaration: String) -> [String] {
        guard let start = declaration.range(of: "##### Enum policy"),
              let end = declaration.range(of: "#### Immutable snapshots") else {
            return ["0.5.0.md has no `##### Enum policy` section before `#### Immutable snapshots`."]
        }
        let section = String(declaration[start.upperBound ..< end.lowerBound])
        let flat = section.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var problems: [String] = []

        var rows: [String: (policy: String, cases: [String])] = [:]
        for line in section.split(separator: "\n") where line.hasPrefix("| `") {
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count == 3, let name = backticked(cells[0]).first else {
                problems.append("The enum policy table has a malformed row: \(line)")
                continue
            }
            if rows[name] != nil { problems.append("\(name) has two rows in the enum policy table.") }
            rows[name] = (cells[1], backticked(cells[2]))
        }

        var errorNames: [String] = []
        if let list = flat.range(of: "error enums (") {
            let tail = flat[list.upperBound...]
            errorNames = backticked(String(tail.prefix { $0 != ")" }))
        } else {
            problems.append("The enum policy section has no `error enums (...)` list of unfrozen enums (D34).")
        }
        if !flat.contains("`GnosticJSONValue` follows the JSON data model") {
            problems.append("GnosticJSONValue is exempt from the table, and the policy section no longer says why.")
        }

        let enums = baselines.flatMap { publicEnums(in: $0) }
        let enumNames = Set(enums.filter { !$0.cases.isEmpty }.map(\.name))
        for found in enums where !found.cases.isEmpty {
            if namedExemptions.contains(found.name) || errorNames.contains(found.name) { continue }
            if found.isError {
                problems.append("\(found.name) is not classified: an error enum belongs on the unfrozen list in 0.5.0.md (D34).")
                continue
            }
            guard let row = rows[found.name] else {
                problems.append("\(found.name) is not classified: add a Frozen or Open row to the enum policy table in 0.5.0.md (D30).")
                continue
            }
            guard row.policy == "Frozen" || row.policy == "Open" else {
                problems.append("\(found.name) must be Frozen or Open in the enum policy table, not `\(row.policy)`.")
                continue
            }
            guard row.policy == "Frozen" else { continue }
            let missing = found.cases.filter { !row.cases.contains($0) }
            let stale = row.cases.filter { !found.cases.contains($0) }
            if !missing.isEmpty {
                problems.append("\(found.name) is Frozen, and its baseline has case \(missing.joined(separator: ", ")) that the table row lacks.")
            }
            if !stale.isEmpty {
                problems.append("\(found.name) is Frozen, and its table row lists \(stale.joined(separator: ", ")), which the baseline lacks.")
            }
            if Set(row.cases).count != row.cases.count {
                problems.append("\(found.name) lists a case twice in its table row.")
            }
        }
        for name in rows.keys where !enumNames.contains(name) {
            problems.append("\(name) has a table row, and no public case-bearing enum of that name is in a baseline.")
        }
        for name in errorNames where !enumNames.contains(name) {
            problems.append("\(name) is on the unfrozen error list, and no public enum of that name is in a baseline.")
        }
        return problems
    }

    /// Whether a baseline line declares a type of this name.
    private static func declares(_ name: String, in line: String) -> Bool {
        for keyword in ["struct", "enum", "class"] where line.contains(" \(keyword) \(name) ") || line.contains(" \(keyword) \(name):") {
            return true
        }
        return false
    }
}
