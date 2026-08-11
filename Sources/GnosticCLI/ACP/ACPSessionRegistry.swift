// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Durable metadata for ACP sessions. Conversation content remains in the
/// remote Timeline; this file only lets a restarted ACP child recover its
/// identity and validate the original client workspace.
actor ACPSessionRegistry {
    private let url: URL
    private var records: [String: ACPSessionRecord]

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
        records = Self.load(from: self.url)
    }

    func create(
        profileFingerprint: String,
        ascendantID: UUID,
        timelineID: UUID,
        cwd: String,
        title: String
    ) throws -> ACPSessionRecord {
        let now = Date()
        let record = ACPSessionRecord(
            id: UUID().uuidString.lowercased(),
            profileFingerprint: profileFingerprint,
            ascendantID: ascendantID,
            timelineID: timelineID,
            cwd: cwd,
            title: title,
            createdAt: now,
            updatedAt: now,
            closedAt: nil
        )
        records[record.id] = record
        try persist()
        return record
    }

    func record(id: String) -> ACPSessionRecord? {
        records[id]
    }

    func list(cwd: String?) -> [ACPSessionRecord] {
        records.values
            .filter { cwd == nil || $0.cwd == cwd }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    func close(id: String) throws -> ACPSessionRecord? {
        guard var record = records[id] else { return nil }
        record.closedAt = Date()
        record.updatedAt = Date()
        records[id] = record
        try persist()
        return record
    }

    func touch(id: String, title: String? = nil) throws {
        guard var record = records[id] else { return }
        record.updatedAt = Date()
        if let title { record.title = title }
        records[id] = record
        try persist()
    }

    private func persist() throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(Array(records.values))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func load(from url: URL) -> [String: ACPSessionRecord] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ACPSessionRecord].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
    }

    private static func defaultURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["GNOSTIC_STATE_HOME"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
                .appendingPathComponent("acp-sessions-v1.json")
        }
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Gnostic", isDirectory: true)
            .appendingPathComponent("acp-sessions-v1.json")
        #else
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state", isDirectory: true)
        return base.appendingPathComponent("gnostic", isDirectory: true)
            .appendingPathComponent("acp-sessions-v1.json")
        #endif
    }
}
