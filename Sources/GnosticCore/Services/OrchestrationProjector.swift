// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation

/// Projects backend-owned models into Gnostic network objects.
@MainActor
public final class OrchestrationProjector {
    private let advertiseObject: (CoatyObject) -> Void
    private let readvertiseObject: (CoatyObject) -> Void
    private var timelines: [UUID: GnosticTimelineObject] = [:]
    private let nodeID: UUID?

    /// Creates a projector using the provided advertisement operations.
    ///
    /// - Parameters:
    ///   - advertise: Publishes a newly advertised local object.
    ///   - readvertise: Publishes a changed local object with the same identity.
    ///   - nodeID: The serving node identity carried by each projection.
    public init(
        advertise: @escaping (CoatyObject) -> Void,
        readvertise: @escaping (CoatyObject) -> Void,
        nodeID: UUID? = nil
    ) {
        advertiseObject = advertise
        readvertiseObject = readvertise
        self.nodeID = nodeID
    }

    /// Creates a projector backed by an Axoloty lifecycle controller.
    ///
    /// - Parameter controller: The controller that publishes lifecycle events.
    public convenience init(controller: ObjectLifecycleController, nodeID: UUID? = nil) {
        self.init(
            advertise: { controller.advertiseDiscoverableObject(object: $0) },
            readvertise: { controller.readvertiseDiscoverableObject(object: $0) },
            nodeID: nodeID
        )
    }

    /// Projects and advertises all local orchestration objects.
    ///
    /// - Parameters:
    ///   - ascendant: The local Ascendant identity.
    ///   - timeline: The local Timeline projection.
    ///   - workspaces: The local Workspace references to advertise.
    public func advertise(
        ascendant: AscendantRuntimeIdentity,
        timeline: AscendantRuntimeTimeline,
        workspaces: [GnosticWorkspaceReference]
    ) {
        advertiseObject(GnosticAscendantObject(identity: ascendant, nodeID: nodeID))
        let timelineObject = GnosticTimelineObject(timeline: timeline, nodeID: nodeID)
        timelines[timeline.id] = timelineObject
        advertiseObject(timelineObject)
        workspaces.forEach { advertiseObject(GnosticWorkspaceObject(workspace: $0)) }
    }

    /// Projects and readvertises a timeline after its attachments change.
    ///
    /// - Parameter timeline: The latest backend timeline state.
    /// - Returns: The timeline object sent in the readvertisement.
    @discardableResult
    public func readvertise(timeline: AscendantRuntimeTimeline) -> GnosticTimelineObject {
        let object = GnosticTimelineObject(timeline: timeline, nodeID: nodeID)
        timelines[timeline.id] = object
        readvertiseObject(object)
        return object
    }
}
