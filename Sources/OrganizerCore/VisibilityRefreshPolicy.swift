import Foundation

public enum VisibilityRefreshPolicy {
    /// A read-only discovery can avoid rebuilding an active visibility assertion
    /// when the requested hidden identities have not changed and none is visibly
    /// present. The caller separately verifies that the assertion and process
    /// inventory are still current.
    public static func canKeepCurrentAssertion(applied: LayoutDocument, current: LayoutDocument,
                                               snapshot: RegistrySnapshot) -> Bool {
        struct HiddenIdentity: Hashable {
            let id: String
            let bundleID: String
        }
        func hiddenIdentities(_ layout: LayoutDocument) -> Set<HiddenIdentity> {
            Set(layout.entries.filter { $0.group == .hidden }
                .map { HiddenIdentity(id: $0.id, bundleID: $0.bundleID) })
        }
        guard hiddenIdentities(applied) == hiddenIdentities(current) else { return false }
        return !snapshot.items.contains { item in
            guard item.entry.group == .hidden,
                  item.availability == .available || item.availability == .overflow,
                  item.canSetVisibility else { return false }
            // System AX rows can remain after their icons disappear. Their
            // presence alone cannot justify replacing an active assertion.
            return ItemRegistry.systemVisibilityTarget(for: item.entry) == nil
        }
    }
}
