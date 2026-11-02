// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A change retained by the catalog after ingesting a network lifecycle event.
public enum NetworkCatalogChange: Sendable {
    /// A supported object was advertised or resolved.
    case advertised(NetworkCatalogEntry)

    /// A listed object was deadvertised by the given provider.
    case deadvertised(objectID: UUID, providerID: String)

    /// A provider published a lifecycle identity deadvertisement.
    ///
    /// Every record owned by that provider was removed from the catalog.
    case providerEvicted(String)
}
