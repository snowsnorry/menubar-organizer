import XCTest
@testable import OrganizerCore

final class SettingsApplyPlanTests: XCTestCase {
    func testPreferencesDoNotRetryPendingLayout() {
        let committed = LayoutDocument()
        var draft = committed
        draft.hideDelay = 9
        XCTAssertEqual(SettingsApplyPlan(committed: committed, draft: draft, pendingLayout: true),
                       SettingsApplyPlan(committed: committed, draft: draft, pendingLayout: false))
        XCTAssertFalse(SettingsApplyPlan(committed: committed, draft: draft, pendingLayout: true).needsLayout)
        draft.launchAtLogin = true
        XCTAssertFalse(SettingsApplyPlan(committed: committed, draft: draft, pendingLayout: true).needsLayout)
    }
    func testUnchangedOKRetriesPendingLayoutOnly() {
        let document = LayoutDocument()
        XCTAssertFalse(SettingsApplyPlan(committed: document, draft: document, pendingLayout: false).needsLayout)
        XCTAssertTrue(SettingsApplyPlan(committed: document, draft: document, pendingLayout: true).needsLayout)
        XCTAssertFalse(SettingsApplyPlan(committed: document, draft: document, pendingLayout: true).needsReordering)
    }
    func testOrderAndVisibilityRequireLayout() {
        let committed = LayoutDocument(entries: [.init(id: "a", bundleID: "a", name: "A"), .init(id: "b", bundleID: "b", name: "B")])
        var draft = committed
        draft.entries.reverse()
        XCTAssertTrue(SettingsApplyPlan(committed: committed, draft: draft, pendingLayout: false).needsLayout)
        XCTAssertTrue(SettingsApplyPlan(committed: committed, draft: draft, pendingLayout: false).needsReordering)
        draft = committed
        draft.entries[0].group = .hidden
        XCTAssertTrue(SettingsApplyPlan(committed: committed, draft: draft, pendingLayout: false).needsLayout)
        XCTAssertFalse(SettingsApplyPlan(committed: committed, draft: draft, pendingLayout: false).needsReordering)
        XCTAssertTrue(SettingsApplyPlan(committed: draft, draft: committed, pendingLayout: false).needsReordering)
        XCTAssertFalse(SettingsApplyPlan(committed: draft, draft: committed, pendingLayout: false,
                                         reorderNewlyVisibleIDs: []).needsReordering)
    }
}
