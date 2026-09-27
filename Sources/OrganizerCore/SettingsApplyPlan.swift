import Foundation

/// Preferences-only saves never replay a previously pending menu-bar layout.
public struct SettingsApplyPlan: Equatable, Sendable {
    public let needsLayout: Bool
    public let needsSave: Bool
    /// Visibility-only removal from the menu bar needs no position-table access.
    public let needsReordering: Bool

    private struct Identity: Equatable {
        let id: String
        let bundleID: String
        let group: ItemGroup
        init(_ entry: LayoutEntry) { id = entry.id; bundleID = entry.bundleID; group = entry.group }
    }

    public init(committed: LayoutDocument, draft: LayoutDocument, pendingLayout: Bool,
                reorderNewlyVisibleIDs: Set<String>? = nil) {
        let layoutChanged = committed.entries.map(Identity.init) != draft.entries.map(Identity.init)
        let preferencesChanged = committed.hideDelay != draft.hideDelay || committed.launchAtLogin != draft.launchAtLogin
        needsLayout = layoutChanged || (pendingLayout && !preferencesChanged)
        needsSave = committed != draft
        let previousVisible = committed.entries(in: .visible).map(\.id)
        let nextVisible = draft.entries(in: .visible).map(\.id)
        let shared = Set(previousVisible).intersection(nextVisible)
        let changedRelativeOrder = previousVisible.filter { shared.contains($0) }
            != nextVisible.filter { shared.contains($0) }
        let newlyVisibleNeedsPosition = nextVisible.contains {
            !previousVisible.contains($0) && (reorderNewlyVisibleIDs?.contains($0) ?? true)
        }
        // A pending visibility retry must not replay a stale saved order.
        // Reordering requires a new visible-order change or a newly revealed row.
        needsReordering = changedRelativeOrder || newlyVisibleNeedsPosition
    }
}
