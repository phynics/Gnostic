// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The form of a Workspace URI that is safe to write to a log.
///
/// A URI may carry credentials in its userinfo or its query. The log form keeps
/// the scheme, host, port, and path, which an operator needs to tell two URIs
/// apart, and drops the userinfo, the query, and the fragment. A URI that does
/// not parse, or whose log form still holds an `@`, becomes a placeholder
/// rather than raw text.
enum WorkspaceURILogForm {
    /// The text that stands in for a URI that cannot be shown safely.
    static let placeholder = "<unparseable URI>"

    /// Returns the log form of `uri`.
    ///
    /// - Parameter uri: A Workspace URI, which may hold credentials.
    /// - Returns: The scheme, host, port, and path of `uri`, or ``placeholder``.
    static func redacted(_ uri: String) -> String {
        guard let components = URLComponents(string: uri) else { return placeholder }
        var form = ""
        if let scheme = components.scheme { form += "\(scheme):" }
        if let host = components.host {
            form += "//\(host)"
            if let port = components.port { form += ":\(port)" }
        }
        form += components.percentEncodedPath
        // A credential that the parser left in the host or the path would show here.
        guard !form.isEmpty, !form.contains("@") else { return placeholder }
        return form
    }
}
