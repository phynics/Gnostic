// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The form of a Workspace URI that is safe to write to a log.
///
/// A URI may carry credentials in its userinfo or its query. Only a
/// hierarchical URI with an authority (`scheme://host...`) gets a log form.
/// That form keeps the scheme, host, port, and path, which an operator needs to
/// tell two URIs apart, and drops the userinfo, the query, and the fragment.
/// Every other text becomes a placeholder, because without an authority the
/// parser cannot say which part is a credential. That covers opaque URIs such
/// as `user:pass` and `workspace:token`, text that is not a URI, a URI with no
/// host, and a URI whose log form still holds an `@`, raw or percent-encoded.
///
/// Known limit: a token placed in an ordinary path segment, such as
/// `workspace://host/t0k3n/repo`, stays in the log form. The meaning of a path
/// segment cannot be inferred.
enum WorkspaceURILogForm {
    /// The text that stands in for a URI that cannot be shown safely.
    static let placeholder = "<unparseable URI>"

    /// Returns the log form of `uri`.
    ///
    /// - Parameter uri: A Workspace URI, which may hold credentials.
    /// - Returns: The scheme, host, port, and path of a `scheme://host` URI,
    ///   or ``placeholder`` for any other text.
    static func redacted(_ uri: String) -> String {
        guard let components = URLComponents(string: uri),
              let scheme = components.scheme, !scheme.isEmpty,
              uri.lowercased().hasPrefix("\(scheme.lowercased())://"),
              let host = components.host, !host.isEmpty else { return placeholder }
        var form = "\(scheme)://\(host)"
        if let port = components.port { form += ":\(port)" }
        form += components.percentEncodedPath
        // A credential that the parser left in the host or the path would show
        // here, as `@` or as its percent-encoded form.
        let decoded = form.removingPercentEncoding ?? form
        guard !form.contains("@"), !decoded.contains("@") else { return placeholder }
        return form
    }
}
