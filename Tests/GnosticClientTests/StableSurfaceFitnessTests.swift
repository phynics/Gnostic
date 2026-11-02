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
}
