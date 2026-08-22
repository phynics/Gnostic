// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKContracts
import PositronicKit

@MainActor
public final class TimelineService {
    private let ascendantIDs: Set<UUID>
    private let registry: NodeRegistry
    private let access: BackendSessionAccess
    private let advertise: @MainActor (AscendantRuntimeTimeline, Bool) -> Void

    convenience init(
        ascendantIDs: Set<UUID>,
        registry: NodeRegistry,
        isClosed: @escaping @MainActor () -> Bool,
        lifecycleGeneration: @escaping @MainActor () -> UInt64 = { 0 },
        isCurrentBackend: @escaping @MainActor (UUID, any AscendantBackend, UInt64) -> Bool = { _, _, _ in true },
        backendLease: @escaping @MainActor (UUID, any AscendantBackend) -> UUID? = { _, _ in nil },
        adapter: @escaping @MainActor (UUID) -> (any AscendantBackend)?,
        lifecycleFailure: @escaping @MainActor (UUID, any AscendantBackend, AscendantBackendLifecycleFailure) async -> Void = { _, _, _ in },
        advertise: @escaping @MainActor (AscendantRuntimeTimeline, Bool) -> Void
    ) {
        self.init(
            ascendantIDs: ascendantIDs,
            registry: registry,
            access: BackendSessionAccess(
                isRunning: { !isClosed() },
                isClosed: isClosed,
                lifecycleGeneration: lifecycleGeneration,
                session: { id in
                    guard let adapter = adapter(id) else { return nil }
                    return AscendantBackendSession(ascendantID: id, backend: adapter, lease: backendLease(id, adapter) ?? UUID(), generation: lifecycleGeneration())
                },
                isCurrent: isCurrentBackend,
                lease: backendLease,
                lifecycleFailure: lifecycleFailure
            ),
            advertise: advertise
        )
    }

    init(
        ascendantIDs: Set<UUID>,
        registry: NodeRegistry,
        access: BackendSessionAccess,
        advertise: @escaping @MainActor (AscendantRuntimeTimeline, Bool) -> Void
    ) {
        self.ascendantIDs = ascendantIDs
        self.registry = registry
        self.access = access
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
        guard !access.isClosed() else { throw NodeRuntimeError.notRunning }
        guard let adapter = access.adapter(ascendantID) else { throw NodeRuntimeError.unknownAscendant(ascendantID) }
        let generation = access.lifecycleGeneration()
        guard access.isCurrent(ascendantID, adapter, generation) else { throw NodeRuntimeError.notRunning }
        let lease = access.lease(ascendantID, adapter)
        let requestedID = UUID.makeVersion4()
        var projectedID = requestedID
        do {
            let timeline = try await adapter.createTimeline(id: requestedID, title: title)
            guard access.isCurrent(ascendantID, adapter, generation) else { throw NodeRuntimeError.notRunning }
            projectedID = timeline.id
            guard timeline.id == requestedID else { throw NodeRuntimeError.missingTimeline(timeline.id) }
            guard access.isCurrent(ascendantID, adapter, generation) else { throw NodeRuntimeError.notRunning }
            _ = try await registry.registerRuntimeTimeline(
                timeline,
                ascendantID: ascendantID,
                backendLease: lease,
                generation: generation
            )
            guard access.isCurrent(ascendantID, adapter, generation) else { throw NodeRuntimeError.notRunning }
            advertise(timeline, false)
            return Self.status(timeline)
        } catch {
            if let backendError = error as? AscendantBackendError,
               case let .lifecycleUnusable(failure) = backendError {
                guard access.isCurrent(ascendantID, adapter, generation) else { throw error }
                await access.lifecycleFailure(ascendantID, adapter, failure)
            } else {
                guard access.isCurrent(ascendantID, adapter, generation) else { throw error }
                if projectedID != requestedID {
                    await adapter.removeTimeline(id: projectedID)
                    guard access.isCurrent(ascendantID, adapter, generation) else { throw error }
                }
                await adapter.removeTimeline(id: requestedID)
                guard access.isCurrent(ascendantID, adapter, generation) else { throw error }
            }
            throw error
        }
    }
    func list() async throws -> [TimelineStatus] {
        guard !access.isClosed() else { throw NodeRuntimeError.notRunning }
        return await registry.listTimelines().map(Self.status)
    }
    func rename(_ request: TimelineUpdateRequest) async throws -> TimelineStatus {
        let ascendantID = try await registry.requireOperatingAscendant(for: request.timelineID)
        guard let adapter = access.adapter(ascendantID) else { throw NodeRuntimeError.unknownAscendant(ascendantID) }
        let generation = access.lifecycleGeneration()
        guard access.isCurrent(ascendantID, adapter, generation) else { throw NodeRuntimeError.notRunning }
        let lease = access.lease(ascendantID, adapter)
        let previous = await registry.timeline(id: request.timelineID)?.timeline
        guard access.isCurrent(ascendantID, adapter, generation) else { throw NodeRuntimeError.notRunning }
        let timeline: AscendantRuntimeTimeline
        do {
            timeline = try await adapter.renameTimeline(id: request.timelineID, title: request.title)
            guard access.isCurrent(ascendantID, adapter, generation) else { throw NodeRuntimeError.notRunning }
        } catch let error as AscendantBackendError {
            if case let .lifecycleUnusable(failure) = error {
                guard access.isCurrent(ascendantID, adapter, generation) else { throw error }
                await access.lifecycleFailure(ascendantID, adapter, failure)
            }
            throw error
        }
        do {
            guard access.isCurrent(ascendantID, adapter, generation) else { throw NodeRuntimeError.notRunning }
            _ = try await registry.commitBackendTimeline(
                timeline,
                ascendantID: ascendantID,
                backendLease: lease,
                generation: generation
            )
            guard access.isCurrent(ascendantID, adapter, generation) else { throw NodeRuntimeError.notRunning }
            advertise(timeline, true)
            return Self.status(timeline)
        }
        catch {
            if let previous {
                do {
                    guard access.isCurrent(ascendantID, adapter, generation) else { throw error }
                    _ = try await adapter.renameTimeline(id: previous.id, title: previous.title)
                    guard access.isCurrent(ascendantID, adapter, generation) else { throw error }
                } catch let rollbackError as AscendantBackendError {
                    if case let .lifecycleUnusable(failure) = rollbackError {
                        guard access.isCurrent(ascendantID, adapter, generation) else { throw error }
                        await access.lifecycleFailure(ascendantID, adapter, failure)
                    }
                } catch {}
            }
            throw error
        }
    }
    static func status(_ timeline: AscendantRuntimeTimeline) -> TimelineStatus { .init(timelineID: timeline.id, title: timeline.title, attachedWorkspaceIDs: timeline.attachedWorkspaceIDs, isArchived: timeline.isArchived, isPrivate: timeline.isPrivate) }

}
