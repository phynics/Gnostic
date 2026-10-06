// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The host-owned bounds a curator proposal must fit.
///
/// The descriptor is immutable for one replay. The curator receives it as an
/// input and can never enlarge a budget or change a version, because the host
/// pairs the proposal with the descriptor it issued (GNO-CTX-004).
public struct ContextDescriptor: Codable, Sendable, Equatable {
    /// The schema version the proposal must use.
    public let schemaVersion: String
    /// The policy version the proposal must use.
    public let policyVersion: String
    /// The maximum number of items in one carry category.
    public let maxItemsPerCategory: Int
    /// The maximum synopsis size in UTF-8 bytes.
    public let maxSynopsisBytes: Int
    /// The maximum item text size in UTF-8 bytes.
    public let maxItemBytes: Int
    /// The maximum citations one item may carry.
    public let maxReferencesPerItem: Int
    /// The maximum total accepted carry size in UTF-8 bytes.
    public let maxTotalAcceptedBytes: Int
    /// The minimum hierarchy fan-out.
    public let minimumFanOut: Int
    /// The maximum hierarchy fan-out.
    public let maximumFanOut: Int

    /// Creates a descriptor.
    public init(
        schemaVersion: String = ContextSchemaVersion.current,
        policyVersion: String = ContextPolicyVersion.current,
        maxItemsPerCategory: Int,
        maxSynopsisBytes: Int,
        maxItemBytes: Int,
        maxReferencesPerItem: Int,
        maxTotalAcceptedBytes: Int,
        minimumFanOut: Int,
        maximumFanOut: Int
    ) {
        self.schemaVersion = schemaVersion
        self.policyVersion = policyVersion
        self.maxItemsPerCategory = maxItemsPerCategory
        self.maxSynopsisBytes = maxSynopsisBytes
        self.maxItemBytes = maxItemBytes
        self.maxReferencesPerItem = maxReferencesPerItem
        self.maxTotalAcceptedBytes = maxTotalAcceptedBytes
        self.minimumFanOut = minimumFanOut
        self.maximumFanOut = maximumFanOut
    }

    /// The descriptor the offline experiment uses.
    public static let `default` = ContextDescriptor(
        maxItemsPerCategory: 64,
        maxSynopsisBytes: 4096,
        maxItemBytes: 1024,
        maxReferencesPerItem: 8,
        maxTotalAcceptedBytes: 65_536,
        minimumFanOut: 4,
        maximumFanOut: 8
    )
}
