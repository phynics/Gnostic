// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Canonical Gnostic object type identifiers advertised through Axoloty.
public enum GnosticObjectType {
    /// The object type for a projected Gnostic Timeline.
    public static let timeline = "me.atkn.gnostic.Timeline"

    /// The object type for a projected Gnostic Workspace.
    public static let workspace = "me.atkn.gnostic.Workspace"

    /// The query-only object type for a public Workspace tool.
    public static let workspaceTool = "me.atkn.gnostic.WorkspaceTool"

    /// The object type for a discovered Runtime instance. It is the only
    /// identity projection a Node advertises (ADR 0021).
    public static let runtimeInstance = "me.atkn.gnostic.RuntimeInstance"

    /// Returns whether an object type is handled by the Gnostic catalog.
    ///
    /// - Parameter objectType: A network object type.
    /// - Returns: `true` when the type is one of Gnostic's canonical types.
    public static func isSupported(_ objectType: String) -> Bool {
        supported.contains(objectType)
    }

    /// Every canonical object type. The architecture fitness test reads this
    /// list to check what the catalog really advertises.
    package static let supported = [timeline, workspace, workspaceTool, runtimeInstance]
}
