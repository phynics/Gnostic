// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKShared
import PositronicKit

@MainActor
public final class TimelineService {
    private let ascendantIDs: Set<UUID>
    private let registry: NodeRegistry
    private let adapter: @MainActor (UUID) -> (any AscendantBackend)?
    private let isClosed: @MainActor () -> Bool
    private let advertise: @MainActor (AscendantRuntimeTimeline, Bool) -> Void

    init(ascendantIDs: Set<UUID>, registry: NodeRegistry, isClosed: @escaping @MainActor () -> Bool, adapter: @escaping @MainActor (UUID) -> (any AscendantBackend)?, advertise: @escaping @MainActor (AscendantRuntimeTimeline, Bool) -> Void) {
        self.ascendantIDs = ascendantIDs; self.registry = registry; self.isClosed = isClosed; self.adapter = adapter; self.advertise = advertise
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
        guard !isClosed() else { throw NodeRuntimeError.notRunning }
        guard let adapter = adapter(ascendantID) else { throw NodeRuntimeError.unknownAscendant(ascendantID) }
        let reservation = try await registry.registerRuntimeTimeline(title: title, ascendantID: ascendantID)
        var projectedID = reservation.id
        do {
            let timeline = try await adapter.createTimeline(id: reservation.id, title: title)
            projectedID = timeline.id
            _ = try await registry.replaceTimeline(timeline)
            advertise(timeline, false)
            return Self.status(timeline)
        } catch {
            if projectedID != reservation.id { await adapter.removeTimeline(id: projectedID) }
            await adapter.removeTimeline(id: reservation.id)
            await registry.removeRuntimeTimeline(id: reservation.id)
            throw error
        }
    }
    func list() async throws -> [TimelineStatus] {
        guard !isClosed() else { throw NodeRuntimeError.notRunning }
        return await registry.listTimelines().map(Self.status)
    }
    func rename(_ request: TimelineUpdateRequest) async throws -> TimelineStatus {
        let ascendantID = try await registry.requireOperatingAscendant(for: request.timelineID)
        guard let adapter = adapter(ascendantID) else { throw NodeRuntimeError.unknownAscendant(ascendantID) }
        let previous = await registry.timeline(id: request.timelineID)?.timeline
        let timeline = try await adapter.renameTimeline(id: request.timelineID, title: request.title)
        do { _ = try await registry.replaceTimeline(timeline); advertise(timeline, true); return Self.status(timeline) }
        catch { if let previous { _ = try? await adapter.renameTimeline(id: previous.id, title: previous.title) }; throw error }
    }
    static func status(_ timeline: AscendantRuntimeTimeline) -> TimelineStatus { .init(timelineID: timeline.id, title: timeline.title, attachedWorkspaceIDs: timeline.attachedWorkspaceIDs, isArchived: timeline.isArchived, isPrivate: timeline.isPrivate) }
}
