// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ACP

/// Disambiguates the SDK's `Protocol` actor from Foundation's Objective-C
/// `Protocol` class for files that also import Foundation.
typealias ACPProtocolLayer = Protocol
