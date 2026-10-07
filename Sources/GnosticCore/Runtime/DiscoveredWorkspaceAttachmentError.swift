// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticProtocol

/// Failures that prevent a discovered workspace from being imported or attached.
///
/// The cases are provider-neutral: a backend reports the failure through the
/// kernel's public seam without leaking a native value.
public enum DiscoveredWorkspaceAttachmentError: Error, Sendable, Equatable {
    /// Attachment is a user-approved operation and approval was not supplied.
    case approvalRequired
    /// The catalog entry is not available, well-formed, and uniquely advertised.
    case unavailable(WorkspaceAttachmentStatus)
    /// The advertised URI cannot form a workspace reference.
    case invalidURI
    /// The requested timeline belongs to another configured runtime.
    case timelineNotOwned(UUID)
}
