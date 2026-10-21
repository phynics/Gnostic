// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticCore

// The manifest is a Core domain model. These aliases preserve the CLI module's
// source compatibility for callers that imported the configuration types from
// the executable target before NodeRuntime moved into GnosticCore.
public typealias NodeManifest = GnosticCore.NodeManifest
public typealias NodeLaunchPlan = GnosticCore.NodeLaunchPlan
public typealias NodeManifestError = GnosticCore.NodeManifestError
