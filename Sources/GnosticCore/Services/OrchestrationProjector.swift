// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKShared

/// Projects local PositronicKit models into Gnostic network objects.
@MainActor
public final class OrchestrationProjector {
    private let advertiseObject: (CoatyObject) -> Void
    private let readvertiseObject: (CoatyObject) -> Void
    private var timelines: [UUID: GnosticTimelineObject] = [:]

    /// Creates a projector using the provided advertisement operations.
    ///
    /// - Parameters:
    ///   - advertise: Publishes a newly advertised local object.
    ///   - readvertise: Publishes a changed local object with the same identity.
    public init(
        advertise: @escaping (CoatyObject) -> Void,
        readvertise: @escaping (CoatyObject) -> Void
    ) {
        advertiseObject = advertise
        readvertiseObject = readvertise
    }

    /// Creates a projector backed by an Axoloty lifecycle controller.
    ///
    /// - Parameter controller: The controller that publishes lifecycle events.
    public convenience init(controller: ObjectLifecycleController) {
        self.init(
            advertise: { controller.advertiseDiscoverableObject(object: $0) },
            readvertise: { controller.readvertiseDiscoverableObject(object: $0) }
        )
    }

    /// Projects and advertises all local orchestration objects.
    ///
    /// - Parameters:
    ///   - agent: The local Ascendant identity.
    ///   - timeline: The local Timeline projection.
    ///   - workspaces: The local workspace references to advertise.
    public func advertise(
        agent: AscendantRuntimeIdentity,
        timeline: AscendantRuntimeTimeline,
        workspaces: [WorkspaceReference]
    ) {
        advertiseObject(GnosticAgentObject(identity: agent))
        let timelineObject = GnosticTimelineObject(timeline: timeline)
        timelines[timeline.id] = timelineObject
        advertiseObject(timelineObject)
        workspaces.forEach { advertiseObject(GnosticWorkspaceObject(workspace: $0)) }
    }

    /// Projects and readvertises a timeline after its attachments change.
    ///
    /// - Parameter timeline: The latest PositronicKit timeline state.
    /// - Returns: The timeline object sent in the readvertisement.
    @discardableResult
    public func readvertise(timeline: AscendantRuntimeTimeline) -> GnosticTimelineObject {
        let object = GnosticTimelineObject(timeline: timeline)
        timelines[timeline.id] = object
        readvertiseObject(object)
        return object
    }
}
