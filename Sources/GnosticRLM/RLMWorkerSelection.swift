// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// The Scheme executors an RLM run can select (ADR 0012).
///
/// The selection is a closed set of names. Turning a selection into a driver is
/// the job of the executor-factory target, which sits outside this harness
/// module so that `GnosticRLM` stays free of executor packages.
public enum RLMWorkerSelection: String, Sendable, CaseIterable {
    case guile
    case chibi
}
