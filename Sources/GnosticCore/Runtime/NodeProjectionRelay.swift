// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKContracts
import PositronicKit

@MainActor
final class NodeProjectionRelay {
    private weak var transport: NodeTransport?

    func bind(_ transport: NodeTransport) { self.transport = transport }

    func projectTimeline(_ timeline: AscendantRuntimeTimeline, replacing: Bool) {
        transport?.projectTimeline(timeline, replacing: replacing)
    }

    func projectAscendant(
        _ identity: AscendantRuntimeIdentity,
        health: AscendantBackendHealth,
        replacing: Bool
    ) {
        transport?.projectAscendant(identity, health: health, replacing: replacing)
    }
}
