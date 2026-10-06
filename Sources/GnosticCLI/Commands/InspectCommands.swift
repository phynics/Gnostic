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
        subcommands: [List.self, Object.self, Node.self, Ascendant.self, Timeline.self, Events.self]
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

        @OptionGroup var formatOptions: OutputFormatOptions

        @MainActor
        func run() async throws {
            let format = try formatOptions.resolved()
            let entries = try await InspectSession(values: connection.values()).collect()
            let filtered = entries.filter { entry in
                guard let type else { return true }
                return entry.objectType == Self.canonicalType(for: type)
            }
            switch format {
            case .human:
                print(InspectRenderer.listText(filtered), terminator: "")
            case .json:
                print(try InspectRenderer.listJSON(filtered))
            }
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

        @OptionGroup var formatOptions: OutputFormatOptions

        @MainActor
        func run() async throws {
            let format = try formatOptions.resolved()
            guard let id = UUID(uuidString: uuid) else {
                throw InspectError.malformedUUID(uuid)
            }
            let entries = try await InspectSession(values: connection.values()).collect()
            let matching = entries.filter { $0.objectID == id }
            let resolution = InspectRenderer.resolution(for: matching)
            let wantsJSON = json || format == .json
            switch resolution {
            case .found(let entry):
                print(try InspectRenderer.objectJSON(entry, compact: json), terminator: wantsJSON ? "\n" : "")
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

    /// `gnostic inspect node` — payload-free live Node diagnostics.
    struct Node: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "node",
            abstract: "Show live, payload-free diagnostics for a running Node."
        )

        @OptionGroup var connection: ConnectionOptions

        @Option(name: .long, help: "Expected provider identity that serves diagnostics.")
        var provider: String?

        @OptionGroup var formatOptions: OutputFormatOptions

        @MainActor
        func run() async throws {
            let format = try formatOptions.resolved()
            let snapshot = try await InspectDiagnosticsSession(values: connection.values())
                .node(providerID: provider)
            switch format {
            case .human:
                print(InspectRenderer.nodeText(snapshot), terminator: "")
            case .json:
                print(try InspectRenderer.diagnosticsJSON(snapshot), terminator: "")
            }
        }
    }

    /// `gnostic inspect ascendant <uuid>` — payload-free live Ascendant diagnostics.
    struct Ascendant: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "ascendant",
            abstract: "Show live, payload-free diagnostics for one Ascendant."
        )

        @OptionGroup var connection: ConnectionOptions

        @Argument(help: "The Ascendant UUID to inspect.")
        var uuid: String

        @Option(name: .long, help: "Expected provider identity that owns the Ascendant.")
        var provider: String?

        @OptionGroup var formatOptions: OutputFormatOptions

        @MainActor
        func run() async throws {
            let format = try formatOptions.resolved()
            guard let id = UUID(uuidString: uuid) else {
                throw InspectError.malformedUUID(uuid)
            }
            let snapshot = try await InspectDiagnosticsSession(values: connection.values())
                .ascendant(id, providerID: provider)
            switch format {
            case .human:
                print(InspectRenderer.ascendantText(snapshot), terminator: "")
            case .json:
                print(try InspectRenderer.diagnosticsJSON(snapshot), terminator: "")
            }
        }
    }

    /// `gnostic inspect timeline <uuid>` — payload-free live Timeline diagnostics.
    struct Timeline: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "timeline",
            abstract: "Show live, payload-free diagnostics for one Timeline."
        )

        @OptionGroup var connection: ConnectionOptions

        @Argument(help: "The Timeline UUID to inspect.")
        var uuid: String

        @Option(name: .long, help: "Expected provider identity that owns the Timeline.")
        var provider: String?

        @OptionGroup var formatOptions: OutputFormatOptions

        @MainActor
        func run() async throws {
            let format = try formatOptions.resolved()
            guard let id = UUID(uuidString: uuid) else {
                throw InspectError.malformedUUID(uuid)
            }
            let snapshot = try await InspectDiagnosticsSession(values: connection.values())
                .timeline(id, providerID: provider)
            switch format {
            case .human:
                print(InspectRenderer.timelineText(snapshot), terminator: "")
            case .json:
                print(try InspectRenderer.diagnosticsJSON(snapshot), terminator: "")
            }
        }
    }

    /// `gnostic inspect events` — bounded raw wire-event envelopes, no payloads.
    struct Events: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "events",
            abstract: "Render the bounded raw wire-event stream without payloads."
        )

        @OptionGroup var connection: ConnectionOptions

        @Flag(name: .long, help: "Keep observing past the observe window until the count or cancellation.")
        var follow = false

        @Option(name: .long, help: "Stop after this many events.")
        var count: Int?

        @OptionGroup var formatOptions: OutputFormatOptions

        @MainActor
        func run() async throws {
            let format = try formatOptions.resolved()
            let events = try await InspectDiagnosticsSession(values: connection.values())
                .events(follow: follow, count: count)
            switch format {
            case .human:
                print(InspectRenderer.eventsText(events), terminator: "")
            case .json:
                print(try InspectRenderer.eventsJSON(events), terminator: "")
            }
        }
    }
}
