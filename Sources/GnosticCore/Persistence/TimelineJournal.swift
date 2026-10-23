// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticProtocol

/// One Gnostic-owned or ACP event in a Timeline's authoritative journal.
///
/// ACP updates are retained as their protocol value, including `_meta` and
/// update kinds this version of Gnostic does not recognize. A Turn admission
/// retains the prompt blocks and their canonical digest.
public enum TimelineJournalPayload: Codable, Sendable, Equatable {
    case timelineCreated(
        title: String,
        runtimeInstanceID: UUID?,
        attachments: [TimelineJournalWorkspaceAttachment]
    )
    case timelineRenamed(title: String)
    case projectChanged(project: Project)
    case workspaceAttached(workspaceID: UUID, uri: String, scope: NodeManifest.AttachmentScope)
    case workspaceDetached(workspaceID: UUID)
    case sessionTransition(
        sessionID: String,
        runtimeInstanceID: UUID,
        state: TimelineJournalSessionState,
        projectKind: Project.Kind?,
        cwd: String
    )
    case turnAdmitted(
        clientTurnID: String,
        admissionDigest: String,
        turnSequence: Int,
        acpVersionTag: String,
        prompt: [ACPContentBlock]
    )
    case acpUpdate(sessionID: String, update: TimelineTurnUpdate)
    case rawACPUpdate(sessionID: String, clientTurnID: String?, update: ACPSessionUpdate)
    case turnCompleted(
        clientTurnID: String,
        outcome: TimelineTurnTerminalOutcome,
        messageID: String?
    )
    case permissionDecision(
        correlationID: String,
        clientTurnID: String,
        decision: String,
        approved: Bool
    )
    case replayEpochStarted(previousEpoch: UUID?, afterSequence: UInt64)
}

/// A credential-free Workspace attachment reference stored in a Timeline log.
public struct TimelineJournalWorkspaceAttachment: Codable, Sendable, Equatable {
    public let workspaceID: UUID
    public let uri: String?
    public let scope: NodeManifest.AttachmentScope

    public init(workspaceID: UUID, uri: String?, scope: NodeManifest.AttachmentScope) {
        self.workspaceID = workspaceID
        self.uri = uri
        self.scope = scope
    }
}

/// The Gnostic-owned state recorded when a Runtime Session changes.
public enum TimelineJournalSessionState: String, Codable, Sendable, Equatable {
    case live
    case resumable
    case lost
    case ambiguous
}

/// One versioned and checksummed event in a Timeline journal.
///
/// The on-disk JSON-lines frame supplies the checksum. The record carries the
/// logical sequence, replay epoch, causal span, and event timestamp used by
/// replay and diagnostics.
public struct TimelineJournalRecord: Codable, Sendable, Equatable {
    /// The one storage schema this implementation can read and write.
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let timelineID: UUID
    public let replayEpoch: UUID
    public let sequence: UInt64
    public let timestamp: Date
    public let causalSpanID: UUID?
    public let payload: TimelineJournalPayload

    internal init(
        formatVersion: Int = TimelineJournalRecord.currentFormatVersion,
        timelineID: UUID,
        replayEpoch: UUID,
        sequence: UInt64,
        timestamp: Date,
        causalSpanID: UUID?,
        payload: TimelineJournalPayload
    ) {
        self.formatVersion = formatVersion
        self.timelineID = timelineID
        self.replayEpoch = replayEpoch
        self.sequence = sequence
        self.timestamp = timestamp
        self.causalSpanID = causalSpanID
        self.payload = payload
    }
}

/// The latest Session transition folded from a Timeline journal.
public struct TimelineJournalSessionProjection: Sendable, Equatable {
    public let sessionID: String
    public let runtimeInstanceID: UUID
    public let state: TimelineJournalSessionState
    public let projectKind: Project.Kind?
    public let cwd: String
    public let startedAt: Date

    public init(
        sessionID: String,
        runtimeInstanceID: UUID,
        state: TimelineJournalSessionState,
        projectKind: Project.Kind?,
        cwd: String,
        startedAt: Date
    ) {
        self.sessionID = sessionID
        self.runtimeInstanceID = runtimeInstanceID
        self.state = state
        self.projectKind = projectKind
        self.cwd = cwd
        self.startedAt = startedAt
    }
}

/// The current Gnostic-owned Timeline fields folded from one journal.
public struct TimelineJournalTimelineProjection: Sendable, Equatable {
    public let timelineID: UUID
    public let title: String
    public let runtimeInstanceID: UUID?
    public let attachments: [TimelineJournalWorkspaceAttachment]
    public let createdAt: Date
    public let updatedAt: Date
    /// Desired placement, retained even between Project change and Session creation.
    public let project: Project?
    public let latestSession: TimelineJournalSessionProjection?

    public init(
        timelineID: UUID,
        title: String,
        runtimeInstanceID: UUID?,
        attachments: [TimelineJournalWorkspaceAttachment],
        createdAt: Date,
        updatedAt: Date,
        latestSession: TimelineJournalSessionProjection?,
        project: Project? = nil
    ) {
        self.timelineID = timelineID
        self.title = title
        self.runtimeInstanceID = runtimeInstanceID
        self.attachments = attachments
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.latestSession = latestSession
        self.project = project
    }
}

/// A cursor names one exact committed position in a Timeline journal.
public struct TimelineReplayCursor: Codable, Sendable, Equatable {
    public let replayEpoch: UUID
    public let sequence: UInt64

    public init(replayEpoch: UUID, sequence: UInt64) {
        self.replayEpoch = replayEpoch
        self.sequence = sequence
    }
}

/// A committed integrity failure that prevents further writes to a Timeline.
public struct TimelineJournalDiagnostic: Sendable, Equatable, LocalizedError {
    public let timelineID: UUID
    public let validThroughSequence: UInt64
    public let reason: String

    public init(timelineID: UUID, validThroughSequence: UInt64, reason: String) {
        self.timelineID = timelineID
        self.validThroughSequence = validThroughSequence
        self.reason = reason
    }

    public var errorDescription: String? {
        "Timeline \(timelineID.uuidString.lowercased()) is quarantined after sequence \(validThroughSequence): \(reason)"
    }
}

/// Whether a Timeline journal accepts writes.
public enum TimelineJournalAvailability: Sendable, Equatable {
    case writable
    case quarantined(TimelineJournalDiagnostic)
}

/// Errors returned by a Timeline journal.
public enum TimelineJournalError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedFormatVersion(actual: Int, supported: Int)
    case quarantined(String)
    case replayEpochDivergence(expected: UUID, actual: UUID)
    case invalidReplayCursor
    case invalidPayload(String)
    case invalidJournalFileName(String)
    case sequenceExhausted
    case reservedPayload
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedFormatVersion(actual, supported):
            "Timeline journal format version \(actual) is unsupported; this version reads \(supported)"
        case let .quarantined(reason):
            "Timeline journal is read-only because it is quarantined: \(reason)"
        case let .replayEpochDivergence(expected, actual):
            "Timeline replay epoch diverged: expected \(expected.uuidString.lowercased()), found \(actual.uuidString.lowercased())"
        case .invalidReplayCursor:
            "Timeline replay cursor does not name a committed journal position"
        case let .invalidPayload(reason):
            "Timeline journal event is invalid: \(reason)"
        case let .invalidJournalFileName(name):
            "Timeline journal file name is invalid or has an unsupported version: \(name)"
        case .sequenceExhausted:
            "Timeline journal sequence is exhausted"
        case .reservedPayload:
            "Replay epoch markers can only be written by the Timeline journal"
        case let .writeFailed(reason):
            "Timeline journal could not commit the event: \(reason)"
        }
    }
}

/// One serialized writer and replay reader for one owning-Node Timeline.
///
/// Opening the journal replays and validates its committed prefix. It
/// truncates only a final frame without its commit newline. A complete invalid
/// frame or invalid sequence/epoch quarantines the journal without modifying
/// the file. Every append synchronizes its frame before returning.
public actor TimelineJournal {
    public let timelineID: UUID
    public let fileURL: URL

    private let log: AppendOnlyEventLog<TimelineJournalRecord>
    private var records: [TimelineJournalRecord]
    private var availability: TimelineJournalAvailability

    /// Opens the journal for `timelineID` and starts a new replay epoch.
    ///
    /// - Throws: ``TimelineJournalError/unsupportedFormatVersion(actual:supported:)``
    ///   if a committed event uses a newer storage format, or a file-system
    ///   error if a new epoch cannot be committed.
    public init(fileURL: URL, timelineID: UUID) throws {
        let log = AppendOnlyEventLog<TimelineJournalRecord>(fileURL: fileURL)
        let scan = try log.scan()
        // Validate the committed prefix before changing any bytes. An unknown
        // format or corrupt sequence must preserve even its uncommitted suffix.
        let validation = try Self.validate(scan.records.map(\.payload), timelineID: timelineID)
        var recovered = validation.validRecords
        var availability: TimelineJournalAvailability = validation.diagnostic.map {
            .quarantined($0)
        } ?? .writable

        if let tail = scan.tail, availability == .writable {
            if tail.kind == .corrupt {
                availability = .quarantined(TimelineJournalDiagnostic(
                    timelineID: timelineID,
                    validThroughSequence: recovered.last?.sequence ?? 0,
                    reason: tail.reason
                ))
            } else {
                _ = try log.recover()
            }
        }

        if availability == .writable {
            let previous = recovered.last
            let epoch = UUID()
            let record = TimelineJournalRecord(
                timelineID: timelineID,
                replayEpoch: epoch,
                sequence: try Self.nextSequence(after: previous?.sequence ?? 0),
                timestamp: Date(),
                causalSpanID: nil,
                payload: .replayEpochStarted(
                    previousEpoch: previous?.replayEpoch,
                    afterSequence: previous?.sequence ?? 0
                )
            )
            _ = try log.append(record)
            recovered.append(record)
        }

        self.timelineID = timelineID
        self.fileURL = fileURL
        self.log = log
        records = recovered
        self.availability = availability
    }

    /// The current write status, including a diagnostic when quarantined.
    public func status() -> TimelineJournalAvailability { availability }

    /// The last committed position, or `nil` when a corrupt journal has no
    /// valid prefix.
    public func currentCursor() -> TimelineReplayCursor? {
        records.last.map { TimelineReplayCursor(replayEpoch: $0.replayEpoch, sequence: $0.sequence) }
    }

    /// Rebuilds the current Timeline fields and Session view from committed events.
    public func timelineProjection() -> TimelineJournalTimelineProjection? {
        var title: String?
        var runtimeInstanceID: UUID?
        var attachments: [UUID: TimelineJournalWorkspaceAttachment] = [:]
        var attachmentOrder: [UUID] = []
        var createdAt: Date?
        var updatedAt: Date?
        var project: Project?
        var latestSession: TimelineJournalSessionProjection?

        for record in records {
            switch record.payload {
            case let .timelineCreated(createdTitle, runtimeID, initialAttachments):
                title = createdTitle
                runtimeInstanceID = runtimeID
                attachments = initialAttachments.reduce(into: [:]) { result, attachment in
                    result[attachment.workspaceID] = attachment
                }
                attachmentOrder = initialAttachments.reduce(into: []) { order, attachment in
                    if !order.contains(attachment.workspaceID) { order.append(attachment.workspaceID) }
                }
                createdAt = record.timestamp
                updatedAt = record.timestamp
            case let .projectChanged(nextProject):
                project = nextProject
                latestSession = nil
            case let .timelineRenamed(newTitle):
                title = newTitle
                updatedAt = record.timestamp
            case let .workspaceAttached(workspaceID, uri, scope):
                if attachments[workspaceID] == nil { attachmentOrder.append(workspaceID) }
                attachments[workspaceID] = TimelineJournalWorkspaceAttachment(
                    workspaceID: workspaceID,
                    uri: scope == .local ? nil : uri,
                    scope: scope
                )
                updatedAt = record.timestamp
            case let .workspaceDetached(workspaceID):
                attachments.removeValue(forKey: workspaceID)
                attachmentOrder.removeAll { $0 == workspaceID }
                updatedAt = record.timestamp
            case let .sessionTransition(sessionID, runtimeID, state, projectKind, cwd):
                if let projectKind {
                    project = projectKind == .local ? .local(cwd) : .scratch
                }
                let startedAt: Date
                if let previousSession = latestSession, previousSession.sessionID == sessionID {
                    startedAt = previousSession.startedAt
                } else {
                    startedAt = record.timestamp
                }
                latestSession = TimelineJournalSessionProjection(
                    sessionID: sessionID,
                    runtimeInstanceID: runtimeID,
                    state: state,
                    projectKind: projectKind,
                    cwd: cwd,
                    startedAt: startedAt
                )
            default:
                break
            }
            updatedAt = record.timestamp
        }

        guard let title, let createdAt, let updatedAt else { return nil }
        return TimelineJournalTimelineProjection(
            timelineID: timelineID,
            title: title,
            runtimeInstanceID: runtimeInstanceID,
            attachments: attachmentOrder.compactMap { attachments[$0] },
            createdAt: createdAt,
            updatedAt: updatedAt,
            latestSession: latestSession,
            project: project
        )
    }

    /// Appends one event after the current committed position.
    ///
    /// The record is synced before it is added to the in-memory replay view or
    /// returned to the caller. Callers must forward or publish the event only
    /// after this method succeeds.
    @discardableResult
    public func append(
        _ payload: TimelineJournalPayload,
        causalSpanID: UUID? = nil
    ) throws -> TimelineJournalRecord {
        guard case .writable = availability else {
            if case let .quarantined(diagnostic) = availability {
                throw TimelineJournalError.quarantined(diagnostic.localizedDescription)
            }
            throw TimelineJournalError.quarantined("journal is not writable")
        }
        guard !Self.isReserved(payload) else { throw TimelineJournalError.reservedPayload }
        if let reason = Self.invalidPayloadReason(payload) {
            throw TimelineJournalError.invalidPayload(reason)
        }
        if case let .acpUpdate(_, update) = payload, update.timelineID != timelineID {
            throw TimelineJournalError.invalidPayload("ACP update names a different Timeline")
        }
        guard let last = records.last else {
            throw TimelineJournalError.quarantined("journal has no replay epoch")
        }

        let record = TimelineJournalRecord(
            timelineID: timelineID,
            replayEpoch: last.replayEpoch,
            sequence: try Self.nextSequence(after: last.sequence),
            timestamp: Date(),
            causalSpanID: causalSpanID,
            payload: payload
        )
        do {
            _ = try log.append(record)
        } catch {
            let reason = error.localizedDescription
            availability = .quarantined(TimelineJournalDiagnostic(
                timelineID: timelineID,
                validThroughSequence: last.sequence,
                reason: "append failed: \(reason)"
            ))
            throw TimelineJournalError.writeFailed(reason)
        }
        records.append(record)
        return record
    }

    // Permission adapters and the shared coordinator may observe the same
    // decision. Commit it once within this journal's serialized writer.
    func recordPermissionDecision(
        correlationID: String, clientTurnID: String, decision: String, approved: Bool
    ) throws {
        let payload = TimelineJournalPayload.permissionDecision(
            correlationID: correlationID, clientTurnID: clientTurnID, decision: decision, approved: approved
        )
        if let prior = records.last(where: {
            if case let .permissionDecision(correlation, turn, _, _) = $0.payload {
                return correlation == correlationID && turn == clientTurnID
            }
            return false
        }) {
            guard prior.payload == payload else {
                throw TimelineJournalError.invalidPayload("Permission decision conflicts with its committed value")
            }
            // A duplicate must still fail closed if the journal was quarantined.
            guard case .writable = availability else {
                throw TimelineJournalError.quarantined("journal is not writable")
            }
            return
        }
        try append(payload)
    }

    /// Returns committed events after `cursor`, in logical append order.
    ///
    /// The cursor must name an exact persisted sequence and epoch. This rejects
    /// stale cursors from another replay branch instead of merging them.
    public func replay(after cursor: TimelineReplayCursor? = nil) throws -> [TimelineJournalRecord] {
        guard let cursor else { return records }
        guard let position = records.first(where: { $0.sequence == cursor.sequence }) else {
            throw TimelineJournalError.invalidReplayCursor
        }
        guard position.replayEpoch == cursor.replayEpoch else {
            throw TimelineJournalError.replayEpochDivergence(
                expected: cursor.replayEpoch,
                actual: position.replayEpoch
            )
        }
        return records.filter { $0.sequence > cursor.sequence }
    }

    private struct Validation {
        let validRecords: [TimelineJournalRecord]
        let diagnostic: TimelineJournalDiagnostic?
    }

    private static func validate(
        _ records: [TimelineJournalRecord],
        timelineID: UUID
    ) throws -> Validation {
        var previousSequence: UInt64 = 0
        var previousEpoch: UUID?
        var seenEpochs: Set<UUID> = []
        var validRecords: [TimelineJournalRecord] = []

        for record in records {
            guard record.formatVersion == TimelineJournalRecord.currentFormatVersion else {
                throw TimelineJournalError.unsupportedFormatVersion(
                    actual: record.formatVersion,
                    supported: TimelineJournalRecord.currentFormatVersion
                )
            }
            guard previousSequence < UInt64.max else {
                return Validation(validRecords: validRecords, diagnostic: TimelineJournalDiagnostic(
                    timelineID: timelineID,
                    validThroughSequence: previousSequence,
                    reason: "sequence is exhausted"
                ))
            }
            let expectedSequence = previousSequence + 1
            guard record.timelineID == timelineID else {
                return Validation(validRecords: validRecords, diagnostic: TimelineJournalDiagnostic(
                    timelineID: timelineID,
                    validThroughSequence: previousSequence,
                    reason: "record names Timeline \(record.timelineID.uuidString.lowercased())"
                ))
            }
            guard record.sequence == expectedSequence else {
                return Validation(validRecords: validRecords, diagnostic: TimelineJournalDiagnostic(
                    timelineID: timelineID,
                    validThroughSequence: previousSequence,
                    reason: "expected sequence \(expectedSequence), found \(record.sequence)"
                ))
            }

            switch record.payload {
            case let .replayEpochStarted(parentEpoch, afterSequence):
                guard afterSequence == previousSequence,
                      parentEpoch == previousEpoch,
                      !seenEpochs.contains(record.replayEpoch) else {
                    return Validation(validRecords: validRecords, diagnostic: TimelineJournalDiagnostic(
                        timelineID: timelineID,
                        validThroughSequence: previousSequence,
                        reason: "invalid replay epoch transition at sequence \(record.sequence)"
                    ))
                }
                if previousSequence == 0 {
                    guard parentEpoch == nil else {
                        return Validation(validRecords: validRecords, diagnostic: TimelineJournalDiagnostic(
                            timelineID: timelineID,
                            validThroughSequence: 0,
                            reason: "initial replay epoch has a parent"
                        ))
                    }
                } else {
                    guard parentEpoch == previousEpoch else {
                        return Validation(validRecords: validRecords, diagnostic: TimelineJournalDiagnostic(
                            timelineID: timelineID,
                            validThroughSequence: previousSequence,
                            reason: "replay epoch does not continue the preceding epoch"
                        ))
                    }
                }
                seenEpochs.insert(record.replayEpoch)
            default:
                guard previousSequence > 0,
                      record.replayEpoch == previousEpoch else {
                    return Validation(validRecords: validRecords, diagnostic: TimelineJournalDiagnostic(
                        timelineID: timelineID,
                        validThroughSequence: previousSequence,
                        reason: "event is outside its replay epoch at sequence \(record.sequence)"
                    ))
                }
                if let reason = Self.invalidPayloadReason(record.payload) {
                    return Validation(validRecords: validRecords, diagnostic: TimelineJournalDiagnostic(
                        timelineID: timelineID,
                        validThroughSequence: previousSequence,
                        reason: "\(reason) at sequence \(record.sequence)"
                    ))
                }
                if case let .acpUpdate(_, update) = record.payload,
                   update.timelineID != timelineID {
                    return Validation(validRecords: validRecords, diagnostic: TimelineJournalDiagnostic(
                        timelineID: timelineID,
                        validThroughSequence: previousSequence,
                        reason: "ACP update names a different Timeline at sequence \(record.sequence)"
                    ))
                }
            }

            previousSequence = record.sequence
            previousEpoch = record.replayEpoch
            validRecords.append(record)
        }

        if !validRecords.isEmpty,
           case .replayEpochStarted(previousEpoch: nil, afterSequence: 0) = validRecords[0].payload,
           validRecords[0].sequence == 1 {
            return Validation(validRecords: validRecords, diagnostic: nil)
        }
        if records.isEmpty { return Validation(validRecords: [], diagnostic: nil) }
        return Validation(validRecords: [], diagnostic: TimelineJournalDiagnostic(
            timelineID: timelineID,
            validThroughSequence: 0,
            reason: "journal does not start with an initial replay epoch"
        ))
    }

    private static func nextSequence(after sequence: UInt64) throws -> UInt64 {
        guard sequence < UInt64.max else { throw TimelineJournalError.sequenceExhausted }
        return sequence + 1
    }

    private static func isReserved(_ payload: TimelineJournalPayload) -> Bool {
        if case .replayEpochStarted = payload { return true }
        return false
    }

    private static func invalidPayloadReason(_ payload: TimelineJournalPayload) -> String? {
        switch payload {
        case let .timelineCreated(title, _, attachments):
            if title.isEmpty { return "Timeline title is empty" }
            if !attachments.allSatisfy(isValid) { return "Timeline creation has an invalid Workspace attachment" }
        case let .projectChanged(project):
            do { try project.validate() }
            catch { return "Project change is invalid: \(error.localizedDescription)" }
        case let .timelineRenamed(title):
            if title.isEmpty { return "Timeline title is empty" }
        case let .workspaceAttached(_, uri, scope):
            if !isValid(uri: uri, scope: scope) { return "Workspace attachment has an invalid scope or URI" }
        case let .sessionTransition(sessionID, _, _, _, cwd):
            if sessionID.isEmpty || cwd.isEmpty { return "Session transition is missing its session ID or cwd" }
        case let .turnAdmitted(clientTurnID, digest, turnSequence, acpVersionTag, prompt):
            guard (try? GnosticWirePayload.canonicalClientTurnID(clientTurnID)) == clientTurnID,
                  turnSequence > 0,
                  !acpVersionTag.isEmpty,
                  TimelineTurnEnvelope.computeAdmissionDigest(prompt: prompt, acpVersionTag: acpVersionTag) == digest else {
                return "Turn admission has an invalid identity, digest, or sequence"
            }
        case let .rawACPUpdate(sessionID, _, _):
            if sessionID.isEmpty { return "ACP update has no session ID" }
        case let .acpUpdate(_, update):
            guard (try? GnosticWirePayload.canonicalClientTurnID(update.clientTurnID)) == update.clientTurnID else {
                return "ACP update has an invalid clientTurnID"
            }
        case let .permissionDecision(correlationID, clientTurnID, _, _):
            guard !correlationID.isEmpty,
                  (try? GnosticWirePayload.canonicalClientTurnID(clientTurnID)) == clientTurnID else {
                return "Permission decision has an invalid correlation or Turn ID"
            }
        case let .turnCompleted(clientTurnID, _, _):
            if (try? GnosticWirePayload.canonicalClientTurnID(clientTurnID)) != clientTurnID {
                return "Turn completion has an invalid clientTurnID"
            }
        case .workspaceDetached, .replayEpochStarted:
            break
        }
        return nil
    }

    private static func isValid(_ attachment: TimelineJournalWorkspaceAttachment) -> Bool {
        isValid(
            uri: attachment.uri ?? "",
            scope: attachment.scope
        )
    }

    private static func isValid(uri: String, scope: NodeManifest.AttachmentScope) -> Bool {
        scope != .network || !uri.isEmpty
    }
}

/// Owns the per-Timeline journal handles for one Node state directory.
///
/// Repeated requests for one Timeline return the same actor, so Timeline
/// operations and Turn updates share one serialized sequence allocator.
public actor TimelineJournalStore {
    public let directoryURL: URL
    private var journals: [UUID: TimelineJournal] = [:]

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    /// Opens or returns the one journal handle for `timelineID`.
    public func journal(for timelineID: UUID) throws -> TimelineJournal {
        if let existing = journals[timelineID] { return existing }
        let url = Self.fileURL(for: timelineID, in: directoryURL)
        let journal = try TimelineJournal(fileURL: url, timelineID: timelineID)
        journals[timelineID] = journal
        return journal
    }

    /// Writes the initial Timeline state only when its journal has no genesis
    /// event. Later configuration changes must use their own journal events.
    public func ensureTimelineCreated(
        timelineID: UUID,
        title: String,
        runtimeInstanceID: UUID?,
        attachments: [NodeManifest.WorkspaceAttachment]
    ) async throws {
        let journal = try journal(for: timelineID)
        if case .quarantined = await journal.status() { return }
        let records = try await journal.replay()
        guard !records.contains(where: { record in
            if case .timelineCreated = record.payload { return true }
            return false
        }) else { return }
        try await journal.append(.timelineCreated(
            title: title,
            runtimeInstanceID: runtimeInstanceID,
            attachments: attachments.map {
                TimelineJournalWorkspaceAttachment(
                    workspaceID: $0.workspaceID,
                    uri: $0.uri,
                    scope: $0.scope
                )
            }
        ))
    }

    /// Rebuilds the current Timeline projection for every journal in this Node.
    public func timelineProjections() async throws -> [UUID: TimelineJournalTimelineProjection] {
        let identifiers = Set(try timelineIDs()).union(journals.keys)
        var projections: [UUID: TimelineJournalTimelineProjection] = [:]
        for timelineID in identifiers.sorted(by: { $0.uuidString < $1.uuidString }) {
            let journal = try journal(for: timelineID)
            if let projection = await journal.timelineProjection() {
                projections[timelineID] = projection
            }
        }
        return projections
    }

    /// Rebuilds one Timeline projection without opening unrelated journal files.
    public func timelineProjection(for timelineID: UUID) async throws -> TimelineJournalTimelineProjection? {
        let journal = try journal(for: timelineID)
        return await journal.timelineProjection()
    }

    /// Lists journal filenames without opening or modifying them.
    public func timelineIDs() throws -> [UUID] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        var identifiers: [UUID] = []
        for file in files {
            let name = file.lastPathComponent
            guard name.hasPrefix("timeline-"), name.hasSuffix(".jsonl") else { continue }
            guard let timelineID = Self.timelineID(from: file) else {
                throw TimelineJournalError.invalidJournalFileName(name)
            }
            identifiers.append(timelineID)
        }
        return identifiers.sorted { $0.uuidString < $1.uuidString }
    }

    /// Resolves the stable versioned journal filename for one Timeline.
    public static func fileURL(for timelineID: UUID, in directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent(
            "timeline-\(timelineID.uuidString.lowercased())-v1.jsonl",
            isDirectory: false
        )
    }

    private static func timelineID(from url: URL) -> UUID? {
        let prefix = "timeline-"
        let suffix = "-v1.jsonl"
        let name = url.lastPathComponent
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let lower = name.index(name.startIndex, offsetBy: prefix.count)
        let upper = name.index(name.endIndex, offsetBy: -suffix.count)
        guard lower <= upper else { return nil }
        let value = String(name[lower..<upper])
        guard let timelineID = UUID(uuidString: value),
              value == timelineID.uuidString.lowercased() else { return nil }
        return timelineID
    }
}

/// Optional backend capability for journaling ACP updates before the backend
/// forwards them into Gnostic's Turn stream.
public struct TimelineJournalRecorder: AscendantBackendOptionalCapability, Sendable {
    private let journals: TimelineJournalStore

    public init(journals: TimelineJournalStore) {
        self.journals = journals
    }

    /// Commits one ACP update that is outside an identified Turn.
    public func appendRawACPUpdate(
        timelineID: UUID,
        sessionID: String,
        clientTurnID: String?,
        update: ACPSessionUpdate,
        causalSpanID: UUID? = nil
    ) async throws {
        let journal = try await journals.journal(for: timelineID)
        try await journal.append(
            .rawACPUpdate(sessionID: sessionID, clientTurnID: clientTurnID, update: update),
            causalSpanID: causalSpanID
        )
    }

    /// Commits one turn-correlated ACP update with its Gnostic replay envelope.
    public func appendTurnUpdate(
        sessionID: String,
        update: TimelineTurnUpdate,
        causalSpanID: UUID? = nil
    ) async throws {
        let journal = try await journals.journal(for: update.timelineID)
        try await journal.append(
            .acpUpdate(sessionID: sessionID, update: update),
            causalSpanID: causalSpanID
        )
    }

    /// Commits one Session transition to its owning Timeline journal.
    public func appendSessionTransition(
        timelineID: UUID,
        sessionID: String,
        runtimeInstanceID: UUID,
        state: TimelineJournalSessionState,
        projectKind: Project.Kind?,
        cwd: String
    ) async throws {
        let journal = try await journals.journal(for: timelineID)
        try await journal.append(.sessionTransition(
            sessionID: sessionID,
            runtimeInstanceID: runtimeInstanceID,
            state: state,
            projectKind: projectKind,
            cwd: cwd
        ))
    }

    /// Commits desired placement and retires the old Session projection.
    public func appendProjectChange(timelineID: UUID, project: Project) async throws {
        let journal = try await journals.journal(for: timelineID)
        try await journal.append(.projectChanged(project: project))
    }

    /// Commits a permission decision before replying to the Runtime.
    public func appendPermissionDecision(
        timelineID: UUID, clientTurnID: String, correlationID: String, decision: String, approved: Bool
    ) async throws {
        let journal = try await journals.journal(for: timelineID)
        try await journal.recordPermissionDecision(
            correlationID: correlationID, clientTurnID: clientTurnID, decision: decision, approved: approved
        )
    }

    /// Reads desired placement and Session state from the authoritative journal.
    public func timelineProjection(for timelineID: UUID) async throws -> TimelineJournalTimelineProjection? {
        try await journals.timelineProjection(for: timelineID)
    }

    /// Reads the latest Session binding from the authoritative Timeline journal.
    public func sessionProjection(for timelineID: UUID) async throws -> TimelineJournalSessionProjection? {
        try await journals.timelineProjection(for: timelineID)?.latestSession
    }
}
