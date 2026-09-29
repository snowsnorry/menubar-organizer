import XCTest
@testable import OrganizerCore

final class VisibilityRefreshPolicyTests: XCTestCase {
    private let hidden = LayoutEntry(id: "app:org.hidden", bundleID: "org.hidden", name: "Hidden", group: .hidden)

    func testKeepsAssertionWhenHiddenIdentityIsAbsentDespiteOtherLayoutChanges() throws {
        let applied = LayoutDocument(entries: [hidden, .init(id: "app:org.visible", bundleID: "org.visible", name: "Visible")])
        let current = LayoutDocument(entries: [.init(id: "app:org.visible", bundleID: "org.visible", name: "Renamed"), hidden], hideDelay: 10)
        let snapshot = try ItemRegistry.reconcile([.init(bundleID: "org.visible", identifier: nil, name: "Renamed")], with: current)
        XCTAssertTrue(VisibilityRefreshPolicy.canKeepCurrentAssertion(applied: applied, current: current, snapshot: snapshot))
    }

    func testRequiresFullCheckWhenHiddenIdentityChangesOrReappears() throws {
        let applied = LayoutDocument(entries: [hidden])
        let visible = try ItemRegistry.reconcile([.init(bundleID: "org.hidden", identifier: nil, name: "Hidden")], with: applied)
        XCTAssertFalse(VisibilityRefreshPolicy.canKeepCurrentAssertion(applied: applied, current: applied, snapshot: visible))

        let changed = LayoutDocument(entries: [.init(id: hidden.id, bundleID: hidden.bundleID, name: hidden.name)])
        let absent = try ItemRegistry.reconcile([], with: changed)
        XCTAssertFalse(VisibilityRefreshPolicy.canKeepCurrentAssertion(applied: applied, current: changed, snapshot: absent))
    }

    func testTimeMachineAccessibilityRowDoesNotForceFullCheck() throws {
        let entry = LayoutEntry(id: ItemRegistry.timeMachinePositionID, bundleID: "com.apple.systemuiserver",
                                name: "Time Machine", group: .hidden)
        let layout = LayoutDocument(entries: [entry])
        let observation = DiscoveredItem(bundleID: entry.bundleID, identifier: "time-machine", name: entry.name,
                                         positionTableKey: "status:com.apple.systemuiserver::com.apple.menuextra.TimeMachine")
        let snapshot = try ItemRegistry.reconcile([observation], with: layout)
        XCTAssertTrue(VisibilityRefreshPolicy.canKeepCurrentAssertion(applied: layout, current: layout, snapshot: snapshot))
    }

    func testSystemModuleAccessibilityRowDoesNotForceFullCheck() throws {
        let entry = LayoutEntry(id: "system-position:module:Bluetooth", bundleID: "com.apple.controlcenter",
                                name: "Bluetooth", group: .hidden)
        let layout = LayoutDocument(entries: [entry])
        let observation = DiscoveredItem(bundleID: entry.bundleID, identifier: nil, name: entry.name,
                                         positionTableKey: "module:Bluetooth")
        let snapshot = try ItemRegistry.reconcile([observation], with: layout)
        XCTAssertTrue(VisibilityRefreshPolicy.canKeepCurrentAssertion(applied: layout, current: layout, snapshot: snapshot))
    }
}
