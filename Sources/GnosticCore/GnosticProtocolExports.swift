// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// GnosticCore builds on the GnosticProtocol wire/contract target. Re-exporting
// it keeps existing `import GnosticCore` consumers source-compatible while the
// wire boundary moves to its own target. New consumers that only need wire
// types should import GnosticProtocol directly.
@_exported import GnosticProtocol
