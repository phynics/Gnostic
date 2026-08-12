// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The broker identity is part of the cache key so a profile cannot leak from
/// one local Gnostic namespace into another.
struct ACPProfileCacheKey: Codable, Equatable, Sendable {
    let host: String
    let port: Int
    let namespace: String
}

/// A short-lived cache for dynamic ACP profile sources. Profile discovery is
/// metadata, not a live-session operation, so a bounded cache avoids opening a
/// new MQTT connection for every Pi startup/configuration evaluation.
struct ACPProfileCache: Sendable {
    static let maxAge: TimeInterval = 30

    private struct Entry: Codable, Sendable {
        let version: Int
        let key: ACPProfileCacheKey
        let generatedAt: Date
        let bundle: ACPProfileBundle
    }

    private let url: URL

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
    }

    func load(for key: ACPProfileCacheKey, now: Date = Date()) -> ACPProfileBundle? {
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.version == 1,
              entry.key == key,
              entry.bundle.version == ACPProtocol.version,
              !entry.bundle.profiles.isEmpty else { return nil }
        let age = now.timeIntervalSince(entry.generatedAt)
        guard age >= 0, age <= Self.maxAge else { return nil }
        return entry.bundle
    }

    func store(
        _ bundle: ACPProfileBundle,
        for key: ACPProfileCacheKey,
        generatedAt: Date = Date()
    ) throws {
        // Do not cache an empty discovery result: a serve process may come up
        // between Pi's initial probes, and that result should not be sticky.
        guard !bundle.profiles.isEmpty else { return }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let entry = Entry(version: 1, key: key, generatedAt: generatedAt, bundle: bundle)
        try JSONEncoder().encode(entry).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func defaultURL() -> URL {
        ACPSessionRegistry.defaultURL()
            .deletingLastPathComponent()
            .appendingPathComponent("acp-profiles-v1.json")
    }
}
