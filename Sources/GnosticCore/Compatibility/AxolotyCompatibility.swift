// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyProtocol
import AxolotyWire
import Foundation

// This file is the single compatibility boundary for the pre-0.6 API names
// still used by Gnostic's public seams. The implementation is backed entirely
// by Axoloty 0.6's bounded runtime and wire values.

public enum CoreType: String, Codable, Sendable {
    case CoatyObject
    case Identity
}

public struct CoatyUUID: Codable, CustomStringConvertible, Hashable, Sendable {
    public let string: String
    private let uuid: UUID

    public init() {
        self.init(foundationUUID: UUID())
    }

    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.init(foundationUUID: uuid)
    }

    private init(foundationUUID uuid: UUID) {
        self.uuid = uuid
        string = uuid.uuidString.lowercased()
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let uuid = UUID(uuidString: value) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid UUID")) }
        self.init(foundationUUID: uuid)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }

    public var description: String { string }
    fileprivate var foundationUUID: UUID { uuid }
}

open class CoatyObject: Codable, @unchecked Sendable {
    open class var objectType: String { "CoatyObject" }
    public var coreType: CoreType
    public var objectType: String
    public var objectId: CoatyUUID
    public var name: String
    public var externalId: String?
    public var parentObjectId: CoatyUUID?
    public var locationId: CoatyUUID?
    public var isDeactivated: Bool?
    public var custom: [String: String] = [:]

    public init(coreType: CoreType, objectType: String, objectId: CoatyUUID, name: String) {
        self.coreType = coreType
        self.objectType = objectType
        self.objectId = objectId
        self.name = name
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        coreType = try c.decode(CoreType.self, forKey: .coreType)
        objectType = try c.decode(String.self, forKey: .objectType)
        objectId = try c.decode(CoatyUUID.self, forKey: .objectId)
        name = try c.decode(String.self, forKey: .name)
        externalId = try c.decodeIfPresent(String.self, forKey: .externalId)
        parentObjectId = try c.decodeIfPresent(CoatyUUID.self, forKey: .parentObjectId)
        locationId = try c.decodeIfPresent(CoatyUUID.self, forKey: .locationId)
        isDeactivated = try c.decodeIfPresent(Bool.self, forKey: .isDeactivated)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(coreType, forKey: .coreType)
        try c.encode(objectType, forKey: .objectType)
        try c.encode(objectId, forKey: .objectId)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(externalId, forKey: .externalId)
        try c.encodeIfPresent(parentObjectId, forKey: .parentObjectId)
        try c.encodeIfPresent(locationId, forKey: .locationId)
        try c.encodeIfPresent(isDeactivated, forKey: .isDeactivated)
    }

    private enum CodingKeys: String, CodingKey {
        case coreType, objectType, objectId, name, externalId, parentObjectId, locationId, isDeactivated
    }

    public static func register(objectType: String, with _: CoatyObject.Type) -> String { objectType }
}

public struct CoatyObjectSnapshot: Codable, Equatable, Sendable {
    public let objectId: String
    public let coreType: CoreType
    public let objectType: String
    public let name: String
    public let externalId: String?
    public let parentObjectId: String?
    public let locationId: String?
    public let isDeactivated: Bool?
    public let payload: String?

    public init(objectId: String, coreType: CoreType, objectType: String, name: String, externalId: String? = nil, parentObjectId: String? = nil, locationId: String? = nil, isDeactivated: Bool? = nil, payload: String? = nil) {
        self.objectId = objectId; self.coreType = coreType; self.objectType = objectType; self.name = name
        self.externalId = externalId; self.parentObjectId = parentObjectId; self.locationId = locationId
        self.isDeactivated = isDeactivated; self.payload = payload
    }

    public func withPayload(_ payload: String?) -> Self {
        .init(objectId: objectId, coreType: coreType, objectType: objectType, name: name, externalId: externalId, parentObjectId: parentObjectId, locationId: locationId, isDeactivated: isDeactivated, payload: payload)
    }

    public func decodeObject() -> CoatyObject? {
        guard let payload else { return nil }
        return try? JSONDecoder().decode(CoatyObject.self, from: Data(payload.utf8))
    }

    public func decodePayload<T: Decodable>(_ type: T.Type) -> T? {
        guard let payload else { return nil }
        return try? JSONDecoder().decode(type, from: Data(payload.utf8))
    }
}

public struct AdvertiseEventSnapshot: Codable, Equatable, Sendable {
    public let sourceId: String?
    public let eventTypeFilter: String?
    public let object: CoatyObjectSnapshot
    public let privateData: String?
    public init(sourceId: String? = nil, eventTypeFilter: String? = nil, object: CoatyObjectSnapshot, privateData: String? = nil) {
        self.sourceId = sourceId; self.eventTypeFilter = eventTypeFilter; self.object = object; self.privateData = privateData
    }
}

public struct AdvertiseEvent: Decodable, @unchecked Sendable {
    public let object: CoatyObject

    public static func with(object: CoatyObject) throws -> Self { .init(object: object) }
    private init(object: CoatyObject) { self.object = object }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        object = try container.decode(CoatyObject.self, forKey: .object)
        if let raw = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(object)) as? [String: Any],
           let tools = raw["tools"] as? [[String: Any]], tools.contains(where: { $0["id"] == nil }) {
            throw AxolotyError.invalidArgument(argument: "object", reason: "advertised tool identifiers are required")
        }
    }

    private enum CodingKeys: String, CodingKey { case object }
}

public enum PayloadCoder {
    public static func decode<T: Decodable>(_ payload: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(payload.utf8))
    }

    public static func decode(_ payload: String) throws -> AdvertiseEvent {
        guard let root = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let object = root["object"] as? [String: Any] else {
            throw AxolotyError.invalidArgument(argument: "payload", reason: "advertise object is required")
        }
        if let tools = object["tools"] as? [[String: Any]], tools.contains(where: { $0["id"] == nil }) {
            throw AxolotyError.invalidArgument(argument: "object", reason: "advertised tool identifiers are required")
        }
        let encoded = try JSONSerialization.data(withJSONObject: root)
        return try JSONDecoder().decode(AdvertiseEvent.self, from: encoded)
    }
}

public struct DeadvertiseEventSnapshot: Codable, Equatable, Sendable {
    public let sourceId: String?
    public let objectIds: [String]
    public init(sourceId: String? = nil, objectIds: [String]) { self.sourceId = sourceId; self.objectIds = objectIds }
}

public struct ResponseEventSnapshot: Codable, Equatable, Sendable {
    public let eventType: String
    public let sourceId: String?
    public let correlationId: String?
    public let payload: String
    public let object: CoatyObjectSnapshot?
    public let objects: [CoatyObjectSnapshot]?
    public init(eventType: String, sourceId: String?, correlationId: String?, payload: String, object: CoatyObjectSnapshot? = nil, objects: [CoatyObjectSnapshot]? = nil) {
        self.eventType = eventType; self.sourceId = sourceId; self.correlationId = correlationId; self.payload = payload; self.object = object; self.objects = objects
    }
    public func decodePayload<T: Decodable>(_ type: T.Type) -> T? { try? JSONDecoder().decode(type, from: Data(payload.utf8)) }
}

public struct DiscoverEventSnapshot: Codable, Equatable, Sendable {
    public let sourceId: String?
    public let correlationId: String?
    public let externalId: String?
    public let objectId: String?
    public let objectTypes: [String]?
    public let coreTypes: [CoreType]?

    public init(sourceId: String? = nil, correlationId: String? = nil, externalId: String? = nil, objectId: String? = nil, objectTypes: [String]? = nil, coreTypes: [CoreType]? = nil) {
        self.sourceId = sourceId; self.correlationId = correlationId; self.externalId = externalId
        self.objectId = objectId; self.objectTypes = objectTypes; self.coreTypes = coreTypes
    }
}

public struct QueryEventSnapshot: Codable, Equatable, Sendable {
    public let sourceId: String?
    public let correlationId: String?
    public let objectTypes: [String]?
    public let coreTypes: [CoreType]?
    public let objectFilter: String?

    public init(sourceId: String? = nil, correlationId: String? = nil, objectTypes: [String]? = nil, coreTypes: [CoreType]? = nil, objectFilter: String? = nil) {
        self.sourceId = sourceId; self.correlationId = correlationId; self.objectTypes = objectTypes
        self.coreTypes = coreTypes; self.objectFilter = objectFilter
    }
}

public struct ChannelEventSnapshot: Codable, Equatable, Sendable {
    public let sourceId: String?
    public let object: CoatyObjectSnapshot?
    public let objects: [CoatyObjectSnapshot]?
    public let channelId: String
    public let eventTypeFilter: String?
    public let privateData: String?
    public init(sourceId: String? = nil, object: CoatyObjectSnapshot? = nil, objects: [CoatyObjectSnapshot]? = nil, channelId: String, eventTypeFilter: String? = nil, privateData: String? = nil) {
        self.sourceId = sourceId; self.object = object; self.objects = objects; self.channelId = channelId; self.eventTypeFilter = eventTypeFilter; self.privateData = privateData
    }
}

public enum CommunicationState: Sendable, Equatable { case offline, online }
public enum OperatingState: Sendable, Equatable { case stopped, started }

public final class Identity: CoatyObject, @unchecked Sendable {
    override public class var objectType: String { "coaty.Identity" }
    public init(name: String = "IdentityObject", objectType: String = Identity.objectType, objectId: CoatyUUID = .init()) {
        super.init(coreType: .Identity, objectType: objectType, objectId: objectId, name: name)
    }
    public required init(from decoder: Decoder) throws { try super.init(from: decoder) }
}

public final class MQTTClientOptions {
    public var host: String
    public var port: UInt16
    public var username: String?
    public var password: String?
    public var shouldTryMDNSDiscovery: Bool
    public var autoReconnect: Bool
    public var enableSSL: Bool
    public init(host: String = "localhost", port: UInt16 = 1883, enableSSL: Bool = false, shouldTryMDNSDiscovery: Bool = false, username: String? = nil, password: String? = nil, autoReconnect: Bool = true) {
        self.host = host; self.port = port; self.enableSSL = enableSSL; self.shouldTryMDNSDiscovery = shouldTryMDNSDiscovery; self.username = username; self.password = password; self.autoReconnect = autoReconnect
    }
}

public final class CommonOptions {
    public var agentIdentity: [String: Any]?
    public init(agentIdentity: [String: Any]? = nil) { self.agentIdentity = agentIdentity }
}

public final class CommunicationOptions {
    public var namespace: String?
    public var shouldEnableCrossNamespacing: Bool
    public var mqttClientOptions: MQTTClientOptions?
    public var shouldAutoStart: Bool
    public init(namespace: String? = nil, shouldEnableCrossNamespacing: Bool = false, mqttClientOptions: MQTTClientOptions? = nil, shouldAutoStart: Bool = false) {
        self.namespace = namespace; self.shouldEnableCrossNamespacing = shouldEnableCrossNamespacing; self.mqttClientOptions = mqttClientOptions; self.shouldAutoStart = shouldAutoStart
    }
}

public final class Configuration {
    public let common: CommonOptions?
    public let communication: CommunicationOptions
    public init(common: CommonOptions? = nil, communication: CommunicationOptions) { self.common = common; self.communication = communication }
}

public final class Components {
    public let controllers: [String: ObjectLifecycleController.Type]
    public let objectTypes: [CoatyObject.Type]
    public init(controllers: [String: ObjectLifecycleController.Type] = [:], objectTypes: [CoatyObject.Type] = []) { self.controllers = controllers; self.objectTypes = objectTypes }
}

public enum CallHandlerResult: Sendable {
    case success(result: String, executionInfo: String? = nil)
    case failure(code: Int, message: String, executionInfo: String? = nil)
}

public struct CallEventSnapshot: Codable, Equatable, Sendable {
    public let sourceId: String?
    public let correlationId: String?
    public let operation: String
    public let parameters: String?
    public let filter: String?
    public init(sourceId: String? = nil, correlationId: String? = nil, operation: String, parameters: String? = nil, filter: String? = nil) {
        self.sourceId = sourceId; self.correlationId = correlationId; self.operation = operation; self.parameters = parameters; self.filter = filter
    }
}

public final class CallHandlerRegistration: @unchecked Sendable {
    private let onCancel: () -> Void
    private(set) public var isCancelled = false
    fileprivate init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    public func cancel() { guard !isCancelled else { return }; isCancelled = true; onCancel() }
}

public final class DiscoverResponderRegistration: @unchecked Sendable {
    private let onCancel: () -> Void
    private(set) public var isCancelled = false
    fileprivate init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    public func cancel() { guard !isCancelled else { return }; isCancelled = true; onCancel() }
}

public final class QueryResponderRegistration: @unchecked Sendable {
    private let onCancel: () -> Void
    private(set) public var isCancelled = false
    fileprivate init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    public func cancel() { guard !isCancelled else { return }; isCancelled = true; onCancel() }
}

public struct DiscoverEvent: Sendable {
    fileprivate let payload: [UInt8]
    fileprivate init(payload: [UInt8]) { self.payload = payload }
    public static func with(objectTypes: [String]) -> Self {
        let data = (try? JSONSerialization.data(withJSONObject: ["objectTypes": objectTypes], options: [.sortedKeys])) ?? Data("{}".utf8)
        return .init(payload: Array(data))
    }
}

public struct QueryEvent: Sendable {
    fileprivate let payload: [UInt8]
    fileprivate init(payload: [UInt8]) { self.payload = payload }

    public static func with(objectTypes: [String], objectFilter: [String: Any]? = nil) -> Self {
        var value: [String: Any] = ["objectTypes": objectTypes]
        if let objectFilter { value["objectFilter"] = objectFilter }
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
        return .init(payload: Array(data))
    }
}

public final class DiscoverResponderRequest: @unchecked Sendable {
    public let snapshot: DiscoverEventSnapshot
    private let resolveAction: (CoatyObject) throws -> Void
    fileprivate init(snapshot: DiscoverEventSnapshot, resolve: @escaping (CoatyObject) throws -> Void) { self.snapshot = snapshot; resolveAction = resolve }
    public func resolve(object: CoatyObject) throws { try resolveAction(object) }
}

public final class QueryResponderRequest: @unchecked Sendable {
    public let snapshot: QueryEventSnapshot
    private let retrieveAction: ([CoatyObject]) throws -> Void
    fileprivate init(snapshot: QueryEventSnapshot, retrieve: @escaping ([CoatyObject]) throws -> Void) {
        self.snapshot = snapshot; retrieveAction = retrieve
    }
    public func retrieve(objects: [CoatyObject]) throws { try retrieveAction(objects) }
    public func retrieve(object: CoatyObject) throws { try retrieve(objects: [object]) }
}

public struct ChannelEvent: @unchecked Sendable {
    fileprivate let channelId: String
    fileprivate let object: CoatyObject?
    fileprivate let objects: [CoatyObject]?
    fileprivate let privateData: [String: Any]?
    public static func with(object: CoatyObject, channelId: String, privateData: [String: Any]? = nil) throws -> Self { .init(channelId: channelId, object: object, objects: nil, privateData: privateData) }
    public static func with(objects: [CoatyObject], channelId: String, privateData: [String: Any]? = nil) throws -> Self { .init(channelId: channelId, object: nil, objects: objects, privateData: privateData) }
}

private func uuid16(_ uuid: UUID) -> UUID16 {
    let bytes = uuid.uuid
    return UUID16(bytes: bytes)
}

private func uuid(_ value: UUID16) -> UUID { UUID(uuid: value.bytes) }

private func jsonObject(_ value: Any) throws -> [UInt8] {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    try GnosticWirePayload.validateEvent(data, context: "Axoloty event payload")
    return Array(data)
}
private func jsonRaw(_ object: CoatyObject) throws -> [UInt8] { Array(try JSONEncoder().encode(object)) }
private func rawString(_ value: Any?) -> String? {
    guard let value else { return nil }
    guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
    return String(decoding: data, as: UTF8.self)
}

@MainActor
public final class ObjectLifecycleController {
    fileprivate weak var communication: CommunicationManager?
    fileprivate init(communication: CommunicationManager) { self.communication = communication }
    public func advertiseDiscoverableObject(object: CoatyObject, shouldSetParentObjectId: Bool = true) {
        if shouldSetParentObjectId { object.parentObjectId = communication?.identity.objectId }
        communication?.publishAdvertise(object)
    }
    public func readvertiseDiscoverableObject(object: CoatyObject) { communication?.publishAdvertise(object) }
    public func deadvertiseDiscoverableObject(object: CoatyObject) { communication?.publishDeadvertise(object) }
}

private actor CompatibilityDispatch {
    private struct CallHandler {
        let operation: String
        let providerID: String?
        let handler: @Sendable (CallEventSnapshot) async throws -> CallHandlerResult
    }

    private var runtime: AxolotyRuntime?
    private var callHandlers: [UUID: CallHandler] = [:]
    private var discoverHandlers: [UUID: @Sendable (DiscoverResponderRequest) async throws -> Void] = [:]
    private var queryHandlers: [UUID: @Sendable (QueryResponderRequest) async throws -> Void] = [:]
    private var advertisedObjects: [String: CoatyObject] = [:]

    func attach(runtime: AxolotyRuntime) { self.runtime = runtime }

    func addCallHandler(id: UUID, operation: String, providerID: String?, handler: @escaping @Sendable (CallEventSnapshot) async throws -> CallHandlerResult) {
        callHandlers[id] = CallHandler(operation: operation, providerID: providerID, handler: handler)
    }

    func removeCallHandler(id: UUID) { callHandlers[id] = nil }

    func addDiscoverHandler(id: UUID, handler: @escaping @Sendable (DiscoverResponderRequest) async throws -> Void) {
        discoverHandlers[id] = handler
    }

    func removeDiscoverHandler(id: UUID) { discoverHandlers[id] = nil }

    func storeAdvertisedObject(_ object: CoatyObject) {
        advertisedObjects[object.objectId.string] = object
    }

    func removeAdvertisedObject(id: String) {
        advertisedObjects[id] = nil
    }

    func addQueryHandler(id: UUID, handler: @escaping @Sendable (QueryResponderRequest) async throws -> Void) {
        queryHandlers[id] = handler
    }

    func removeQueryHandler(id: UUID) { queryHandlers[id] = nil }

    func handleCall(_ invocation: RuntimeInvocation) async throws -> RuntimeHandlerResult {
        guard case let .deliver(delivery) = invocation.action else { return .noResponse }
        guard let operation = invocation.operation,
              let correlationID = delivery.routingKey.correlationID else {
            return .noResponse
        }
        let json = (try? JSONSerialization.jsonObject(with: Data(delivery.payload))) as? [String: Any] ?? [:]
        let parameters = json["parameters"].flatMap(rawString)
        let filter = json["filter"].flatMap(rawString)
        let snapshot = CallEventSnapshot(
            sourceId: uuid(delivery.routingKey.sourceID).uuidString.lowercased(),
            correlationId: uuid(correlationID).uuidString.lowercased(),
            operation: operation,
            parameters: parameters,
            filter: filter
        )
        for entry in callHandlers.values {
            guard entry.operation == operation && matches(entry.providerID, filter: filter) else { continue }
            do {
                switch try await entry.handler(snapshot) {
                case let .success(result, executionInfo):
                    var response: [String: Any] = ["result": (try JSONSerialization.jsonObject(with: Data(result.utf8)))]
                    if let executionInfo { response["executionInfo"] = try JSONSerialization.jsonObject(with: Data(executionInfo.utf8)) }
                    return .response(try jsonObject(response))
                case let .failure(code, message, _):
                    return .remoteError(code: UInt16(clamping: code), message: message)
                }
            } catch {
                throw error
            }
        }
        return .noResponse
    }

    private func matches(_ providerID: String?, filter: String?) -> Bool {
        guard let providerID else { return true }
        guard let filter else { return true }
        guard
              let data = filter.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let conditions = root["conditions"] as? [Any],
              conditions.count == 2,
              let property = conditions[0] as? String,
              property == "objectId",
              let expression = conditions[1] as? [Any],
              expression.count == 2,
              let operatorCode = expression[0] as? Int,
              operatorCode == 7,
              let value = expression[1] as? String else { return false }
        return value.caseInsensitiveCompare(providerID) == .orderedSame
    }

    func handleDiscover(_ invocation: RuntimeInvocation) async throws -> RuntimeHandlerResult {
        guard case let .deliver(delivery) = invocation.action,
              let correlationID = delivery.routingKey.correlationID,
              let runtime else { return .noResponse }
        let json = (try? JSONSerialization.jsonObject(with: Data(delivery.payload))) as? [String: Any] ?? [:]
        let snapshot = DiscoverEventSnapshot(
            sourceId: uuid(delivery.routingKey.sourceID).uuidString.lowercased(),
            correlationId: uuid(correlationID).uuidString.lowercased(),
            externalId: json["externalId"] as? String,
            objectId: json["objectId"] as? String,
            objectTypes: json["objectTypes"] as? [String]
        )
        for handler in discoverHandlers.values {
            let request = DiscoverResponderRequest(snapshot: snapshot) { object in
                let objectPayload = try jsonObject(["object": JSONSerialization.jsonObject(with: Data(jsonRaw(object)))])
                Task { _ = await runtime.respond(.resolve(correlationID: correlationID, payload: objectPayload)) }
            }
            try await handler(request)
        }
        for object in advertisedObjects.values {
            guard snapshot.objectTypes?.contains(object.objectType) != false else { continue }
            let objectPayload = try jsonObject(["object": JSONSerialization.jsonObject(with: Data(jsonRaw(object)))])
            _ = await runtime.respond(.resolve(correlationID: correlationID, payload: objectPayload))
        }
        return .noResponse
    }

    func handleQuery(_ invocation: RuntimeInvocation) async throws -> RuntimeHandlerResult {
        guard case let .deliver(delivery) = invocation.action,
              let correlationID = delivery.routingKey.correlationID else { return .noResponse }
        let json = (try? JSONSerialization.jsonObject(with: Data(delivery.payload))) as? [String: Any] ?? [:]
        let snapshot = QueryEventSnapshot(
            sourceId: uuid(delivery.routingKey.sourceID).uuidString.lowercased(),
            correlationId: uuid(correlationID).uuidString.lowercased(),
            objectTypes: json["objectTypes"] as? [String],
            coreTypes: (json["coreTypes"] as? [String])?.compactMap(CoreType.init(rawValue:)),
            objectFilter: json["objectFilter"].flatMap(rawString)
        )
        for handler in queryHandlers.values {
            var retrievedObjects: [CoatyObject] = []
            let request = QueryResponderRequest(snapshot: snapshot) { objects in
                retrievedObjects.append(contentsOf: objects)
            }
            try await handler(request)
            guard !retrievedObjects.isEmpty else { continue }
            let rawObjects = try retrievedObjects.map { try JSONSerialization.jsonObject(with: Data(jsonRaw($0))) }
            return .response(try jsonObject(["objects": rawObjects]))
        }
        return .noResponse
    }
}

@MainActor
public final class CommunicationManager {
    public let namespace: String
    public let identity: Identity
    private let runtime: AxolotyRuntime
    private var startTask: Task<Void, Error>?
    private var stateContinuations: [UUID: AsyncStream<CommunicationState>.Continuation] = [:]
    private var advertiseContinuations: [UUID: (objectType: String?, continuation: AsyncStream<AdvertiseEventSnapshot>.Continuation)] = [:]
    private var deadvertiseContinuations: [UUID: AsyncStream<DeadvertiseEventSnapshot>.Continuation] = [:]
    private var responseContinuations: [UUID: (correlationID: String, continuation: AsyncStream<ResponseEventSnapshot>.Continuation)] = [:]
    private var channelContinuations: [UUID: (channelID: String, continuation: AsyncStream<ChannelEventSnapshot>.Continuation)] = [:]
    private let dispatch: CompatibilityDispatch
    private var eventTasks: [Task<Void, Never>] = []
    private var pendingAdvertisements: [String: [UInt8]] = [:]
    private var isRuntimeReady = false
    private var isStarted = false

    public convenience init(identity: Identity, communicationOptions: CommunicationOptions, commonOptions: CommonOptions?) throws {
        guard let mqtt = communicationOptions.mqttClientOptions else { throw AxolotyError.invalidArgument(argument: "mqttClientOptions", reason: "is required") }
        try self.init(identity: identity, namespace: communicationOptions.namespace ?? "-", mqtt: mqtt)
    }

    private init(identity: Identity, namespace: String, mqtt: MQTTClientOptions) throws {
        self.identity = identity; self.namespace = namespace
        let dispatch = CompatibilityDispatch()
        self.dispatch = dispatch
        let runtimeIdentity = try RuntimeIdentity(id: uuid16(identity.objectId.foundationUUID), name: identity.name)
        let capacities = try RuntimeCapacities(
            protocolMaximumPayloadBytes: GnosticWirePayload.maximumBytes,
            protocolMaximumTopicBytes: 65_536
        )
        var builder = try RuntimeDefinition.Builder(identity: runtimeIdentity, namespace: namespace, limits: capacities)
        let callOperations = [
            GnosticWorkspaceProvider.invocationOperation,
            AscendantTurnProvider.turnOperation,
            AscendantTurnProvider.replayOperation,
            AscendantPermissionProvider.responseOperation,
            WorkspaceOpsProvider.listOperation,
            WorkspaceOpsProvider.attachOperation,
            WorkspaceOpsProvider.detachOperation,
            TimelineStatusProvider.statusOperation,
            TimelineManagementProvider.createOperation,
            TimelineManagementProvider.listOperation,
            TimelineManagementProvider.updateOperation,
        ]
        for operation in callOperations {
            try builder.respond(to: .call(operation: operation), maximumConcurrentInvocations: 16) { invocation in
                try await dispatch.handleCall(invocation)
            }
        }
        try builder.respond(to: .discover, maximumConcurrentInvocations: 16) { invocation in
            try await dispatch.handleDiscover(invocation)
        }
        try builder.respond(to: .query, maximumConcurrentInvocations: 16) { invocation in
            try await dispatch.handleQuery(invocation)
        }
        let advertise = try builder.events(matching: .family(.advertise), buffering: .dropOldest(capacity: 64))
        let deadvertise = try builder.events(matching: .family(.deadvertise), buffering: .dropOldest(capacity: 64))
        let resolve = try builder.events(matching: .family(.resolve), buffering: .dropOldest(capacity: 64))
        let retrieves = try builder.events(matching: .family(.retrieve), buffering: .dropOldest(capacity: 64))
        let returns = try builder.events(matching: .family(.returnEvent), buffering: .dropOldest(capacity: 64))
        let calls = try builder.events(matching: .family(.call), buffering: .dropOldest(capacity: 64))
        let permissionChannel = try builder.events(matching: .channel(identifier: "me.atkn.gnostic.ascendant.permission.response"), buffering: .dropOldest(capacity: 64))
        let turnChannel = try builder.events(matching: .channel(identifier: "me.atkn.gnostic.ascendant.turn.update"), buffering: .dropOldest(capacity: 64))
        self.runtime = AxolotyRuntime(definition: try builder.finish(), transport: try MQTTBinding(configuration: .init(host: mqtt.host, port: mqtt.port, usesTLS: mqtt.enableSSL, username: mqtt.username, password: mqtt.password)))
        self.eventStreams = [advertise, deadvertise, resolve, retrieves, returns, calls, permissionChannel, turnChannel]
        Task { await dispatch.attach(runtime: self.runtime) }
    }

    private var eventStreams: [RuntimeEventStream]

    public func start() throws {
        guard !isStarted else { return }
        isStarted = true
        let runtime = self.runtime
        startTask = Task { @MainActor in
            do {
                try await runtime.start()
                self.isRuntimeReady = true
                self.emitState(.online)
                self.startEventPumps()
                await self.flushPendingAdvertisements()
            } catch {
                self.emitState(.offline)
                throw error
            }
        }
    }

    private func startEventPumps() {
        guard eventTasks.isEmpty else { return }
        let entries: [(RuntimeEventFamily, String?, RuntimeEventStream)] = [
            (.advertise, nil, eventStreams[0]),
            (.deadvertise, nil, eventStreams[1]),
            (.resolve, nil, eventStreams[2]),
            (.retrieve, nil, eventStreams[3]),
            (.returnEvent, nil, eventStreams[4]),
            (.call, nil, eventStreams[5]),
            (.channel, "me.atkn.gnostic.ascendant.permission.response", eventStreams[6]),
            (.channel, "me.atkn.gnostic.ascendant.turn.update", eventStreams[7]),
        ]
        for (family, channelID, stream) in entries {
            eventTasks.append(Task { @MainActor [weak self] in
                guard let self else { return }
                for await value in stream { self.emit(value, family: family, channelID: channelID) }
            })
        }
    }

    public func startAndWaitUntilReady() async throws { try start(); try await startTask?.value }
    public func stop() { eventTasks.forEach { $0.cancel() }; eventTasks.removeAll(); isRuntimeReady = false; Task { await runtime.stop() }; isStarted = false; emitState(.offline) }

    public func observeCommunicationStateStream() async -> AsyncStream<CommunicationState> {
        let id = UUID(); let pair = AsyncStream<CommunicationState>.makeStream(bufferingPolicy: .bufferingNewest(8)); stateContinuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.stateContinuations[id] = nil } }
        return pair.stream
    }

    public func observeAdvertiseStream(withObjectType objectType: String) async throws -> AsyncStream<AdvertiseEventSnapshot> { subscribeAdvertise(objectType: objectType) }
    public func observeAdvertiseStream() async -> AsyncStream<AdvertiseEventSnapshot> { subscribeAdvertise(objectType: nil) }
    public func observeDeadvertiseStream() async -> AsyncStream<DeadvertiseEventSnapshot> { subscribeDeadvertise() }
    public func observeChannelStream(channelId: String) async throws -> AsyncStream<ChannelEventSnapshot> { subscribeChannel(channelID: channelId) }

    public func publishDiscover(_ event: DiscoverEvent) async -> AsyncStream<ResponseEventSnapshot> {
        let id = UUID(); let responseStream = subscribeResponse(correlationID: id.uuidString.lowercased())
        _ = await runtime.request(.discover(correlationID: uuid16(id), payload: event.payload, timeoutMS: nil))
        return responseStream
    }

    public func publishQuery(_ event: QueryEvent, timeout: Duration = .seconds(5)) async -> AsyncStream<ResponseEventSnapshot> {
        let id = UUID(); let responseStream = subscribeResponse(correlationID: id.uuidString.lowercased())
        let timeoutMS = UInt32(max(1, timeout.components.seconds * 1000 + Int64(timeout.components.attoseconds / 1_000_000_000_000_000)))
        _ = await runtime.request(.query(correlationID: uuid16(id), payload: event.payload, timeoutMS: timeoutMS))
        return responseStream
    }

    public func call(operation: String, parameters: String? = nil, context: ContextFilter? = nil, timeout: Duration) async throws -> UnaryCallResult {
        let id = UUID(); let stream = subscribeResponse(correlationID: id.uuidString.lowercased())
        var payload: [String: Any] = [:]
        if let parameters { payload["parameters"] = try JSONSerialization.jsonObject(with: Data(parameters.utf8)) }
        if let context { payload["filter"] = try filterObject(context) }
        let timeoutMS = UInt32(max(1, timeout.components.seconds * 1000 + Int64(timeout.components.attoseconds / 1_000_000_000_000_000)))
        _ = await runtime.request(.call(correlationID: uuid16(id), operation: operation, payload: try jsonObject(payload), timeoutMS: timeoutMS))
        let response = try await firstResponse(from: stream, timeout: timeout)
        guard let envelope = response.decodePayload(ReturnEnvelope.self) else {
            return UnaryCallResult(result: response.payload, executionInfo: nil, sourceId: response.sourceId)
        }
        guard let error = envelope.error else {
            return UnaryCallResult(result: envelope.result ?? "null", executionInfo: envelope.executionInfo, sourceId: response.sourceId)
        }
        throw RemoteCallFailure(code: error.code, message: error.message)
    }

    public func publishAdvertise(_ event: AdvertiseEvent) {
        publishAdvertise(event.object)
    }

    public func publishAdvertise(_ object: CoatyObject) {
        guard let data = try? jsonRaw(object), let raw = try? JSONSerialization.jsonObject(with: Data(data)) else { return }
        guard let payload = try? jsonObject(["object": raw]) else { return }
        pendingAdvertisements[object.objectId.string] = payload
        Task { await dispatch.storeAdvertisedObject(object) }
        guard isRuntimeReady else { return }
        Task { _ = await runtime.publish(.advertise(payload)) }
    }
    fileprivate func publishDeadvertise(_ object: CoatyObject) {
        pendingAdvertisements[object.objectId.string] = nil
        Task { await dispatch.removeAdvertisedObject(id: object.objectId.string) }
        guard let payload = try? jsonObject(["objectIds": [object.objectId.string] as [String]]) else { return }
        Task { _ = await runtime.publish(.deadvertise(payload)) }
    }
    public func publishChannel(_ event: ChannelEvent) { guard let payload = try? channelPayload(event) else { return }; Task { _ = await runtime.publish(.channel(identifier: event.channelId, payload: payload)) } }

    public func registerCallHandler(operation: String, context: CoatyObject? = nil, handler: @escaping @Sendable (CallEventSnapshot) async throws -> CallHandlerResult) async throws -> CallHandlerRegistration {
        let id = UUID()
        await dispatch.addCallHandler(id: id, operation: operation, providerID: context?.objectId.string, handler: handler)
        return CallHandlerRegistration { [dispatch] in Task { await dispatch.removeCallHandler(id: id) } }
    }

    public func registerDiscoverResponder(handler: @escaping @Sendable (DiscoverResponderRequest) async throws -> Void) async -> DiscoverResponderRegistration {
        let id = UUID()
        await dispatch.addDiscoverHandler(id: id, handler: handler)
        return DiscoverResponderRegistration { [dispatch] in Task { await dispatch.removeDiscoverHandler(id: id) } }
    }

    public func registerQueryResponder(handler: @escaping @Sendable (QueryResponderRequest) async throws -> Void) async -> QueryResponderRegistration {
        let id = UUID()
        await dispatch.addQueryHandler(id: id, handler: handler)
        return QueryResponderRegistration { [dispatch] in Task { await dispatch.removeQueryHandler(id: id) } }
    }

    private func emitState(_ state: CommunicationState) { stateContinuations.values.forEach { _ = $0.yield(state) } }

    private func flushPendingAdvertisements() async {
        let payloads = pendingAdvertisements.values
        pendingAdvertisements.removeAll()
        for payload in payloads {
            _ = await runtime.publish(.advertise(payload))
        }
    }

    private func subscribeAdvertise(objectType: String?) -> AsyncStream<AdvertiseEventSnapshot> {
        let pair = AsyncStream<AdvertiseEventSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(64)); let id = UUID()
        advertiseContinuations[id] = (objectType, pair.continuation)
        pair.continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.advertiseContinuations[id] = nil } }
        return pair.stream
    }

    private func subscribeDeadvertise() -> AsyncStream<DeadvertiseEventSnapshot> {
        let pair = AsyncStream<DeadvertiseEventSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(64)); let id = UUID()
        deadvertiseContinuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.deadvertiseContinuations[id] = nil } }
        return pair.stream
    }

    private func subscribeResponse(correlationID: String) -> AsyncStream<ResponseEventSnapshot> {
        let pair = AsyncStream<ResponseEventSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(64)); let id = UUID()
        responseContinuations[id] = (correlationID, pair.continuation)
        pair.continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.responseContinuations[id] = nil } }
        return pair.stream
    }

    private func subscribeChannel(channelID: String) -> AsyncStream<ChannelEventSnapshot> {
        let pair = AsyncStream<ChannelEventSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(64)); let id = UUID()
        channelContinuations[id] = (channelID, pair.continuation)
        pair.continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.channelContinuations[id] = nil } }
        return pair.stream
    }

    private func emit(_ value: RuntimeEventValue, family: RuntimeEventFamily, channelID: String? = nil) {
        // The typed stream conversion is kept below the transport/runtime
        // boundary. Unsupported family values are simply not projected.
        switch family {
        case .advertise:
            if let event = convertAdvertise(value) { advertiseContinuations.values.forEach { if $0.objectType == nil || $0.objectType == event.object.objectType { _ = $0.continuation.yield(event) } } }
        case .deadvertise:
            if let event = convertDeadvertise(value) { deadvertiseContinuations.values.forEach { _ = $0.yield(event) } }
        case .resolve, .retrieve, .returnEvent:
            if let event = convertResponse(value, family: family) {
                responseContinuations.values.forEach { if $0.correlationID == event.correlationId { _ = $0.continuation.yield(event) } }
            }
        case .channel:
            if let channelID, let event = convertChannel(value, channelID: channelID) { channelContinuations.values.forEach { if $0.channelID == channelID { _ = $0.continuation.yield(event) } } }
        default: break
        }
    }

    private func convertAdvertise(_ value: RuntimeEventValue) -> AdvertiseEventSnapshot? { guard let object = objectSnapshot(value.value) else { return nil }; return .init(sourceId: uuid(value.context.sourceID).uuidString.lowercased(), object: object) }
    private func convertDeadvertise(_ value: RuntimeEventValue) -> DeadvertiseEventSnapshot? { guard let json = try? JSONSerialization.jsonObject(with: Data(value.value)) as? [String: Any], let ids = json["objectIds"] as? [String] else { return nil }; return .init(sourceId: uuid(value.context.sourceID).uuidString.lowercased(), objectIds: ids) }
    private func convertResponse(_ value: RuntimeEventValue, family: RuntimeEventFamily) -> ResponseEventSnapshot? {
        let payload = String(decoding: value.value, as: UTF8.self)
        let json = (try? JSONSerialization.jsonObject(with: Data(value.value))) as? [String: Any]
        let objects = (json?["objects"] as? [[String: Any]])?.compactMap(snapshotObject)
        let eventType: String = switch family { case .resolve: "RSV"; case .retrieve: "RTV"; default: "RTN" }
        return .init(eventType: eventType, sourceId: uuid(value.context.sourceID).uuidString.lowercased(), correlationId: value.context.correlationID.map { uuid($0).uuidString.lowercased() }, payload: payload, object: objectSnapshot(value.value), objects: objects)
    }
    private func convertCall(_ value: RuntimeEventValue) -> CallEventSnapshot? { guard let json = try? JSONSerialization.jsonObject(with: Data(value.value)) as? [String: Any] else { return nil }; return .init(sourceId: uuid(value.context.sourceID).uuidString.lowercased(), correlationId: value.context.correlationID.map { uuid($0).uuidString.lowercased() }, operation: "", parameters: rawString(json["parameters"]), filter: rawString(json["filter"])) }
    private func convertChannel(_ value: RuntimeEventValue, channelID: String) -> ChannelEventSnapshot? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(value.value)) as? [String: Any] else { return nil }
        let object = snapshotObject(json["object"])
        let objects = (json["objects"] as? [[String: Any]])?.compactMap(snapshotObject)
        let privateData = json["privateData"].flatMap(rawString)
        return .init(sourceId: uuid(value.context.sourceID).uuidString.lowercased(), object: object, objects: objects, channelId: channelID, eventTypeFilter: channelID, privateData: privateData)
    }
    private func objectSnapshot(_ bytes: [UInt8]) -> CoatyObjectSnapshot? { guard let envelope = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any], let raw = envelope["object"] else { return nil }; return snapshotObject(raw) }
    private func snapshotObject(_ raw: Any?) -> CoatyObjectSnapshot? {
        guard let raw, let data = try? JSONSerialization.data(withJSONObject: raw), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = json["objectId"] as? String, let type = json["objectType"] as? String, let name = json["name"] as? String else { return nil }
        return .init(objectId: id, coreType: CoreType(rawValue: json["coreType"] as? String ?? "CoatyObject") ?? .CoatyObject, objectType: type, name: name, externalId: json["externalId"] as? String, parentObjectId: json["parentObjectId"] as? String, locationId: json["locationId"] as? String, isDeactivated: json["isDeactivated"] as? Bool, payload: String(decoding: data, as: UTF8.self))
    }
}

public typealias ContextFilter = ObjectFilter

public struct UnaryCallResult: Equatable, Sendable { public let result: String; public let executionInfo: String?; public let sourceId: String? }
public struct RemoteCallFailure: Error, Equatable, Sendable { public let code: Int; public let message: String; public init(code: Int, message: String) { self.code = code; self.message = message } }
private struct ReturnEnvelope: Decodable {
    let result: String?
    let executionInfo: String?
    let error: ErrorEnvelope?

    private enum CodingKeys: String, CodingKey { case result, executionInfo, error }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let string = try? container.decode(String.self, forKey: .result) {
            result = string
        } else if let value = try? container.decode(NetworkDynamicValue.self, forKey: .result),
                  let data = try? JSONEncoder().encode(value) {
            result = String(decoding: data, as: UTF8.self)
        } else {
            result = nil
        }
        if let string = try? container.decode(String.self, forKey: .executionInfo) {
            executionInfo = string
        } else if let value = try? container.decode(NetworkDynamicValue.self, forKey: .executionInfo),
                  let data = try? JSONEncoder().encode(value) {
            executionInfo = String(decoding: data, as: UTF8.self)
        } else {
            executionInfo = nil
        }
        error = try container.decodeIfPresent(ErrorEnvelope.self, forKey: .error)
    }
}
private struct ErrorEnvelope: Decodable { let code: Int; let message: String }

private func firstResponse(from stream: AsyncStream<ResponseEventSnapshot>, timeout: Duration) async throws -> ResponseEventSnapshot {
    try await withThrowingTaskGroup(of: ResponseEventSnapshot?.self) { group in
        group.addTask {
            for await response in stream {
                return response
            }
            return nil
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        defer { group.cancelAll() }
        guard let response = try await group.next() ?? nil else {
            throw AxolotyError.runtime(code: .timedOut, reason: "The unary call timed out after \(timeout)")
        }
        return response
    }
}

private func channelPayload(_ event: ChannelEvent) throws -> [UInt8] {
    var value: [String: Any] = [:]
    if let object = event.object { value["object"] = try JSONSerialization.jsonObject(with: Data(jsonRaw(object))) }
    if let objects = event.objects { value["objects"] = try objects.map { try JSONSerialization.jsonObject(with: Data(jsonRaw($0))) } }
    if let privateData = event.privateData { value["privateData"] = privateData }
    return try jsonObject(value)
}

public struct ObjectFilter: @unchecked Sendable {
    public let condition: ObjectFilterCondition
    public init(condition: ObjectFilterCondition) { self.condition = condition }
}

public struct ObjectFilterCondition: @unchecked Sendable {
    public let property: ObjectFilterProperty
    public let expression: FilterExpression
    public init(property: ObjectFilterProperty, expression: FilterExpression) { self.property = property; self.expression = expression }
}

public struct ObjectFilterProperty: @unchecked Sendable {
    public let name: String
    public init(_ name: String) { self.name = name }
}

public enum FilterExpression: @unchecked Sendable { case equals(FilterOperand) }
public struct FilterOperand: @unchecked Sendable { public let value: String; public init(_ value: String) { self.value = value } }

private func filterObject(_ context: ObjectFilter) throws -> [String: Any] {
    let expression: [Any]
    switch context.condition.expression {
    case let .equals(operand): expression = [7, operand.value]
    }
    return ["conditions": [context.condition.property.name, expression]]
}

@MainActor
public final class Container {
    public private(set) var identity: Identity?
    public private(set) var communicationManager: CommunicationManager?
    private var lifecycleController: ObjectLifecycleController?
    private init(identity: Identity, communication: CommunicationManager, lifecycle: ObjectLifecycleController) { self.identity = identity; communicationManager = communication; lifecycleController = lifecycle }
    public static func resolve(components: Components, configuration: Configuration) throws -> Container {
        let name = configuration.common?.agentIdentity?["name"] as? String ?? "IdentityObject"
        let identity = Identity(name: name); let communication = try CommunicationManager(identity: identity, communicationOptions: configuration.communication, commonOptions: configuration.common); let lifecycle = ObjectLifecycleController(communication: communication); return Container(identity: identity, communication: communication, lifecycle: lifecycle)
    }
    public func getController(name: String) -> ObjectLifecycleController? { name == "ObjectLifecycleController" ? lifecycleController : nil }
    public func startAndWaitUntilReady() async throws { try await communicationManager?.startAndWaitUntilReady() }
    public func shutdown() { communicationManager?.stop() }
}
