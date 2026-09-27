import Foundation

/// Some status items use an owner name rather than the application's bundle ID
/// in MenuBarAgent's private position table (for example Razer).
public enum PositionTableKeyResolver {
    public enum Failure: Error, Equatable { case unmatched, ambiguous }

    public static func resolve(item: DiscoveredItem, inventory: [DiscoveredItem],
                               tableKeys: Set<String>) throws -> String {
        guard item.isSupported, item.isDirectlyAccessible,
              let bundle = item.bundleID, !bundle.isEmpty else { throw Failure.unmatched }
        guard inventory.filter({ $0.bundleID == bundle }).count == 1 else { throw Failure.ambiguous }

        let bundlePrefix = "status:\(bundle)::"
        let bundleMatches = tableKeys.filter { $0.hasPrefix(bundlePrefix) }
        if let identifier = item.identifier, !identifier.isEmpty {
            let exact = bundlePrefix + identifier
            if tableKeys.contains(exact) { return exact }
        }
        if bundleMatches.count == 1 { return bundleMatches.first! }
        if bundleMatches.count > 1 { throw Failure.ambiguous }

        // A name fallback is allowed only when no bundle-owned table entry
        // exists, one visible process uses that name, and the table has one
        // matching owner. A stale or spoofed name then cannot select among
        // several plausible entries.
        let owner = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty, !owner.contains("::"),
              !inventory.contains(where: { $0.name == owner && $0.bundleID != bundle }) else {
            throw Failure.unmatched
        }
        let ownerMatches = tableKeys.filter { $0.hasPrefix("status:\(owner)::") }
        guard ownerMatches.count == 1 else {
            throw ownerMatches.isEmpty ? Failure.unmatched : Failure.ambiguous
        }
        let only = ownerMatches.first!
        if let identifier = item.identifier, !identifier.isEmpty,
           only != "status:\(owner)::\(identifier)" { throw Failure.unmatched }
        return only
    }
}
