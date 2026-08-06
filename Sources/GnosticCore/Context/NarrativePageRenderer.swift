// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Renders and freezes immutable narrative pages.
///
/// Rendering is deterministic and high contrast, readable without color, and
/// free of application chrome. Pages are value-immutable: freezing does not
/// mutate prior pages, and re-rendering identical input is byte-for-byte
/// deterministic. Relevant pages are selected using GNO-007 retrieval signals.
public struct NarrativePageRenderer: Sendable {
    private var pages: [NarrativePageID: NarrativePage] = [:]

    /// Creates an empty page renderer.
    public init() {}

    /// Freezes a set of entries into an immutable page.
    ///
    /// - Parameters:
    ///   - entries: The entries to summarize on the page.
    ///   - title: The page title.
    /// - Returns: The frozen immutable page.
    @discardableResult
    public mutating func freeze(entries: [NarrativeEntry], title: String) -> NarrativePage {
        let id = NarrativePageID()
        let page = Self.render(entries: entries, title: title, id: id)
        pages[id] = page
        return page
    }

    /// Returns a previously frozen page by identifier, if present.
    public func page(id: NarrativePageID) -> NarrativePage? {
        pages[id]
    }

    /// Deterministically renders entries into immutable bytes (a `NarrativePage`)
    /// without mutating or storing the result.
    public func render(entries: [NarrativeEntry], title: String) -> NarrativePage {
        Self.render(entries: entries, title: title, id: NarrativePageID())
    }

    /// Selects relevant frozen pages for the current turn using GNO-007
    /// retrieval signals (relevant source entry identifiers).
    ///
    /// - Parameters:
    ///   - relevantEntryIDs: Source entry identifiers deemed relevant this turn.
    ///   - limit: The maximum number of pages to return.
    /// - Returns: The bounded set of relevant pages.
    public func selectRelevantPages(relevantEntryIDs: [NarrativeEntryID], limit: Int) -> [NarrativePage] {
        let relevant = Set(relevantEntryIDs)
        return pages.values
            .filter { page in
                page.sourceEntryIDs.contains { relevant.contains($0) }
            }
            .sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
            .prefix(limit)
            .map { $0 }
    }

    private static func render(entries: [NarrativeEntry], title: String, id: NarrativePageID) -> NarrativePage {
        let sorted = entries.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
        let indexText = renderIndex(sorted: sorted, title: title)
        let renderedBytes = Array(indexText.utf8)
        let digest = contentDigest(of: renderedBytes)
        return NarrativePage(
            id: id,
            sourceEntryIDs: sorted.map(\.id),
            contentDigest: digest,
            renderedBytes: renderedBytes,
            indexText: indexText,
            title: title
        )
    }

    private static func renderIndex(sorted: [NarrativeEntry], title: String) -> String {
        var lines: [String] = ["# \(title)", ""]
        for entry in sorted {
            let label: String
            switch entry.kind {
            case .episode: label = "Episode"
            case .arcUpdate: label = "Arc Update"
            case .lesson: label = "Lesson"
            case .openThread: label = "Open Thread"
            case .operationalSelfModel: label = "Self Model"
            }
            lines.append("\(label): \(entry.observation)")
            if !entry.interpretation.isEmpty {
                lines.append("  -> \(entry.interpretation)")
            }
            if let thread = entry.openThread {
                lines.append("  thread: \(thread.summary)")
            }
            for id in entry.source.workspaceIDs {
                lines.append("  workspace: \(id.uuidString)")
            }
            for tool in entry.source.toolIDs {
                lines.append("  tool: \(tool)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func contentDigest(of bytes: [UInt8]) -> String {
        // FNV-1a 64-bit; deterministic across identical inputs.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}