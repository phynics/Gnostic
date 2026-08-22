// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKContracts
import PositronicKit

@MainActor
public final class TimelineService {
    private let ascendantIDs: Set<UUID>
    private let registry: NodeRegistry
    private let backendProvider: any BackendSessionProviding
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
            backendProvider: ClosureBackendSessionProvider(
                isRunning: { !isClosed() },
                lifecycleGeneration: lifecycleGeneration,
                adapter: adapter,
                current: isCurrentBackend,
                backendLease: backendLease,
                failure: lifecycleFailure,
                backend: { _ in throw NodeRuntimeError.notRunning }
            ),
            advertise: advertise
        )
    }

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
        let adapter = session.backend
        let generation = session.generation
        let lease = backendProvider.lease(for: ascendantID, backend: adapter)
        guard backendProvider.isCurrentSession(session) else { throw NodeRuntimeError.notRunning }
        let requestedID = UUID.makeVersion4()
        var projectedID = requestedID
        do {
            let timeline = try await adapter.createTimeline(id: requestedID, title: title)
            guard backendProvider.isCurrentSession(session) else { throw NodeRuntimeError.notRunning }
            projectedID = timeline.id
            guard timeline.id == requestedID else { throw NodeRuntimeError.missingTimeline(timeline.id) }
            guard backendProvider.isCurrentSession(session) else { throw NodeRuntimeError.notRunning }
            _ = try await registry.registerRuntimeTimeline(
                timeline,
                ascendantID: ascendantID,
                backendLease: lease,
                generation: generation
            )
            guard backendProvider.isCurrentSession(session) else { throw NodeRuntimeError.notRunning }
            advertise(timeline, false)
            return Self.status(timeline)
        } catch {
            if let backendError = error as? AscendantBackendError,
               case let .lifecycleUnusable(failure) = backendError {
                guard backendProvider.isCurrentSession(session) else { throw error }
                await backendProvider.markLifecycleFailure(session, failure: failure)
            } else {
                guard backendProvider.isCurrentSession(session) else { throw error }
                if projectedID != requestedID {
                    await adapter.removeTimeline(id: projectedID)
                    guard backendProvider.isCurrentSession(session) else { throw error }
                }
                await adapter.removeTimeline(id: requestedID)
                guard backendProvider.isCurrentSession(session) else { throw error }
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
        guard let session = backendProvider.session(for: ascendantID) else { throw NodeRuntimeError.unknownAscendant(ascendantID) }
        let adapter = session.backend
        let generation = session.generation
        let lease = backendProvider.lease(for: ascendantID, backend: adapter)
        guard backendProvider.isCurrentSession(session) else { throw NodeRuntimeError.notRunning }
        let previous = await registry.timeline(id: request.timelineID)?.timeline
        guard backendProvider.isCurrentSession(session) else { throw NodeRuntimeError.notRunning }
        let timeline: AscendantRuntimeTimeline
        do {
            timeline = try await adapter.renameTimeline(id: request.timelineID, title: request.title)
            guard backendProvider.isCurrentSession(session) else { throw NodeRuntimeError.notRunning }
        } catch let error as AscendantBackendError {
            if case let .lifecycleUnusable(failure) = error {
                guard backendProvider.isCurrentSession(session) else { throw error }
                await backendProvider.markLifecycleFailure(session, failure: failure)
            }
            throw error
        }
        do {
            guard backendProvider.isCurrentSession(session) else { throw NodeRuntimeError.notRunning }
            _ = try await registry.commitBackendTimeline(
                timeline,
                ascendantID: ascendantID,
                backendLease: lease,
                generation: generation
            )
            guard backendProvider.isCurrentSession(session) else { throw NodeRuntimeError.notRunning }
            advertise(timeline, true)
            return Self.status(timeline)
        }
        catch {
            if let previous {
                do {
                    guard backendProvider.isCurrentSession(session) else { throw error }
                    _ = try await adapter.renameTimeline(id: previous.id, title: previous.title)
                    guard backendProvider.isCurrentSession(session) else { throw error }
                } catch let rollbackError as AscendantBackendError {
                    if case let .lifecycleUnusable(failure) = rollbackError {
                        guard backendProvider.isCurrentSession(session) else { throw error }
                        await backendProvider.markLifecycleFailure(session, failure: failure)
                    }
                } catch {}
            }
            throw error
        }
    }
    static func status(_ timeline: AscendantRuntimeTimeline) -> TimelineStatus { .init(timelineID: timeline.id, title: timeline.title, attachedWorkspaceIDs: timeline.attachedWorkspaceIDs, isArchived: timeline.isArchived, isPrivate: timeline.isPrivate) }

}
