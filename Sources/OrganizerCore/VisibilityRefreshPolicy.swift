import Foundation

public enum VisibilityRefreshPolicy {
    /// Passive diagnostics cannot revoke an accepted restriction. AX rows may
    /// reappear or become ambiguous without proving that hiding stopped working.
    /// Only changed hidden identities require applying a different layout.
    public static func canKeepCurrentAssertion(applied: LayoutDocument, current: LayoutDocument,
                                               snapshot: RegistrySnapshot,
                                               failedSystemTargets: Set<String> = []) -> Bool {
        struct HiddenIdentity: Hashable {
            let id: String
            let bundleID: String
        }
        func hiddenIdentities(_ layout: LayoutDocument) -> Set<HiddenIdentity> {
            Set(layout.entries.filter { $0.group == .hidden }
                .map { HiddenIdentity(id: $0.id, bundleID: $0.bundleID) })
        }
        return hiddenIdentities(applied) == hiddenIdentities(current)
    }
}
