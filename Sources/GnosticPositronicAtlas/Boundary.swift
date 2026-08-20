// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticCore
import PositronicKit

/// The optional home for Positronic-specific continuity work.
///
/// RESET-006 ships only this boundary marker. Atlas behavior, persistence, and
/// context semantics are intentionally deferred to a later increment and do
/// not become part of `GnosticCore`.
public enum GnosticPositronicAtlas {
    /// The boundary has no runtime behavior in the 0.3 baseline.
    public static let isScaffoldOnly = true

}
