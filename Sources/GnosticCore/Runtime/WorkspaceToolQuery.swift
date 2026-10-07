// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Constructs and reads the standard Axoloty object-filter form used by the
/// query-only Workspace tool catalog.
public enum GnosticWorkspaceToolQuery {
    /// Builds the bounded object filter for one Workspace tool page.
    ///
    /// - Parameters:
    ///   - workspaceID: The Workspace whose tools are queried.
    ///   - page: The zero-based page index.
    /// - Returns: The Axoloty object filter.
    public static func filter(workspaceID: UUID, page: Int) -> [String: Any] {
        [
            "conditions": [
                "and": [
                    ["workspaceID", [7, workspaceID.uuidString.lowercased()]],
                    ["page", [7, page]],
                ],
            ],
        ]
    }

    /// Reads one typed value out of an encoded object filter.
    ///
    /// - Parameters:
    ///   - type: The value type to read.
    ///   - key: The filter key to find.
    ///   - raw: The encoded filter string.
    /// - Returns: The value, or `nil` when it is absent.
    public static func value<T>(_ type: T.Type, key: String, in raw: String?) -> T? {
        guard let raw, let data = raw.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return find(type, key: key, in: root)
    }

    private static func find<T>(_ type: T.Type, key: String, in value: Any) -> T? {
        if let condition = value as? [Any], condition.count == 2,
           let property = condition[0] as? String, property == key,
           let expression = condition[1] as? [Any], expression.count == 2,
           let equals = expression[0] as? Int, equals == 7 {
            return expression[1] as? T
        }
        if let object = value as? [String: Any] {
            for child in object.values {
                if let result: T = find(type, key: key, in: child) { return result }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let result: T = find(type, key: key, in: child) { return result }
            }
        }
        return nil
    }
}
