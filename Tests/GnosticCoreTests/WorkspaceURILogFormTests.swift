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
        ("WORKSPACE://Host.Example/Repo", "WORKSPACE://Host.Example/Repo"),
    ])
    func keepsWhatTellsTwoURIsApart(uri: String, expected: String) {
        #expect(WorkspaceURILogForm.redacted(uri) == expected)
    }

    @Test("only a scheme://host URI gets a log form; every other text becomes the placeholder", arguments: [
        // Opaque URIs: no authority, so userinfo and tokens sit in the path.
        "user:pass",
        "workspace:token-secret",
        "workspace:user:pass%40host/repo",
        "workspace:user:pass@host/repo",
        // Arbitrary text, which URLComponents would percent-encode instead of reject.
        "this is secret text",
        "secret-token-only",
        // No host.
        "workspace://",
        "workspace:///only/a/path",
        "/srv/workspaces/root",
        // Not parseable at all, or an @ left behind after decoding.
        "workspace://user:s3cr3t@host with space/path",
        "workspace://host%40evil/path",
        "workspace://host/user%40pass",
        "",
    ])
    func placeholderForEveryOtherForm(uri: String) {
        let form = WorkspaceURILogForm.redacted(uri)
        #expect(form == WorkspaceURILogForm.placeholder)
        for secret in ["s3cr3t", "pass", "token-secret", "secret"] { #expect(!form.contains(secret)) }
    }
}
