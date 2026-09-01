// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation

@MainActor
public final class TimelineService {
    private let ascendantIDs: Set<UUID>
    private let registry: NodeRegistry
    private let backendProvider: any BackendSessionProviding
    private let advertise: @MainActor (AscendantRuntimeTimeline, Bool) -> Void

    init(
        ascendantIDs: Set<UUID>,
        registry: NodeRegistry,
        backendProvider: any BackendSessionProviding,
        advertise: @escaping @MainActor (AscendantRuntimeTimeline, Bool) -> Void
    ) {
        self.ascendantIDs = ascendantIDs
        self.registry = registry
        self.backendProvider = backendProvider
        self.advertise = advertise
    }

    func selectAscendant(requested ascendantID: UUID?) throws -> UUID {
        if let ascendantID {
            guard ascendantIDs.contains(ascendantID) else { throw NodeRuntimeError.unknownAscendant(ascendantID) }
            return ascendantID
        }
        guard !ascendantIDs.isEmpty else { throw NodeRuntimeError.noConfiguredAscendant }
        guard ascendantIDs.count == 1 else { throw NodeRuntimeError.ambiguousAscendant }
        return ascendantIDs.first!
    }

    func status(for id: UUID) async throws -> TimelineStatus {
        guard let record = await registry.timeline(id: id) else { throw NodeRuntimeError.missingTimeline(id) }
        return Self.status(record.timeline)
    }
    func create(title: String, ascendantID: UUID) async throws -> TimelineStatus {
        guard !backendProvider.isClosed else { throw NodeRuntimeError.notRunning }
        guard let session = backendProvider.session(for: ascendantID) else { throw NodeRuntimeError.unknownAscendant(ascendantID) }
        let requestedID = UUID.makeVersion4()
        var createdID: UUID?
        do {
            let timeline = try await session.createTimeline(id: requestedID, title: title)
            createdID = timeline.id
            _ = try await registry.registerRuntimeTimeline(timeline, context: session.context)
            advertise(timeline, false)
            return Self.status(timeline)
        } catch {
            if let createdID {
                _ = try? await session.removeTimeline(id: createdID)
            }
            throw error
        }
    }
    func list() async throws -> [TimelineStatus] {
        guard !backendProvider.isClosed else { throw NodeRuntimeError.notRunning }
        return await registry.listTimelines().map(Self.status)
    }
    func rename(_ request: TimelineUpdateRequest) async throws -> TimelineStatus {
        let ascendantID = try await registry.requireOperatingAscendant(for: request.timelineID)
        guard let session = backendProvider.session(for: ascendantID) else { throw NodeRuntimeError.notRunning }
        let previous = await registry.timeline(id: request.timelineID)?.timeline
        let timeline = try await session.timeline(id: request.timelineID)
        let projection = try await timeline.rename(to: request.title)
        do {
            _ = try await registry.commitBackendTimeline(projection, context: session.context)
            advertise(projection, true)
            return Self.status(projection)
        } catch {
            if let previous {
                _ = try? await timeline.rename(to: previous.title)
            }
            throw error
        }
    }
    static func status(_ timeline: AscendantRuntimeTimeline) -> TimelineStatus { .init(timelineID: timeline.id, title: timeline.title, attachedWorkspaceIDs: timeline.attachedWorkspaceIDs, isArchived: timeline.isArchived, isPrivate: timeline.isPrivate) }

}
