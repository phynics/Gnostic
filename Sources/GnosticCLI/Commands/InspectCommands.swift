// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Axoloty
import Foundation
import GnosticCore

/// `gnostic inspect` — list and dump advertised Gnostic objects.
struct InspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Inspect advertised Gnostic objects on the broker.",
        subcommands: [List.self, Object.self]
    )

    /// Common broker connection options, overridable per invocation.
    struct ConnectionOptions: ParsableArguments {
        @Option(name: .long, help: "MQTT broker host (overrides config).")
        var host: String?

        @Option(name: .long, help: "MQTT broker port (overrides config).")
        var port: Int?

        @Option(name: .long, help: "MQTT namespace (overrides config).")
        var namespace: String?

        @Option(name: .long, help: "Discovery collection window in seconds.")
        var observeSeconds: Double = 1.0

        /// The plain connection values used by the session.
        func values() -> InspectConnectionValues {
            InspectConnectionValues(
                host: host,
                port: port,
                namespace: namespace,
                observeSeconds: observeSeconds
            )
        }
    }

    /// `gnostic inspect list [--type ...]` — one line per advertised object.
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List advertised Gnostic objects."
        )

        @OptionGroup var connection: ConnectionOptions

        @Option(name: .long, help: "Filter by object type: ascendant, timeline, or workspace.")
        var type: String?

        @MainActor
        func run() async throws {
            let entries = try await InspectSession(values: connection.values()).collect()
            let filtered = entries.filter { entry in
                guard let type else { return true }
                return entry.objectType == Self.canonicalType(for: type)
            }
            print(InspectRenderer.listText(filtered), terminator: "")
        }

        static func canonicalType(for alias: String) -> String {
            switch alias.lowercased() {
            case "ascendant": GnosticObjectType.ascendant
            case "timeline": GnosticObjectType.timeline
            case "workspace": GnosticObjectType.workspace
            default: alias
            }
        }
    }

    /// `gnostic inspect object <uuid>` — dump one object's catalogued shape.
    struct Object: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "object",
            abstract: "Dump a single object's catalogued representation."
        )

        @OptionGroup var connection: ConnectionOptions

        @Argument(help: "The object UUID to inspect.")
        var uuid: String

        @Flag(name: .long, help: "Emit compact single-line JSON.")
        var json = false

        @MainActor
        func run() async throws {
            guard let id = UUID(uuidString: uuid) else {
                throw InspectError.malformedUUID(uuid)
            }
            let entries = try await InspectSession(values: connection.values()).collect()
            let matching = entries.filter { $0.objectID == id }
            let resolution = InspectRenderer.resolution(for: matching)
            switch resolution {
            case .found(let entry):
                print(try InspectRenderer.objectJSON(entry, compact: json), terminator: json ? "\n" : "")
            case .unknown:
                FileHandle.standardError.write(Data("No advertised object matches '\(uuid)'.\n".utf8))
                throw ExitCode(2)
            case .ambiguous:
                let providers = matching.map(\.providerID).joined(separator: ", ")
                FileHandle.standardError.write(Data("Object '\(uuid)' is advertised by multiple providers: \(providers).\n".utf8))
                throw ExitCode(2)
            }
        }
    }
}
