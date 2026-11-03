// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing

@testable import GnosticCore

@Suite("Workspace URI log form")
struct WorkspaceURILogFormTests {
    @Test("userinfo, query, and fragment are dropped; scheme, host, port, and path stay", arguments: [
        ("workspace://user:s3cr3t@host.example/path/to?token=hunter2#frag", "workspace://host.example/path/to"),
        ("workspace://host.example:8443/repo?token=hunter2", "workspace://host.example:8443/repo"),
        ("workspace://token@host/path", "workspace://host/path"),
        ("workspace://peer-workspace-0123", "workspace://peer-workspace-0123"),
        ("/srv/workspaces/root", "/srv/workspaces/root"),
    ])
    func keepsWhatTellsTwoURIsApart(uri: String, expected: String) {
        #expect(WorkspaceURILogForm.redacted(uri) == expected)
    }

    @Test("a URI that does not parse, or that leaves an @ behind, becomes a placeholder", arguments: [
        "workspace://user:s3cr3t@host with space/path",
        "workspace:user:s3cr3t@host/path",
        "",
    ])
    func placeholderForUnsafeText(uri: String) {
        let form = WorkspaceURILogForm.redacted(uri)
        #expect(form == WorkspaceURILogForm.placeholder)
        #expect(!form.contains("s3cr3t"))
    }
}
